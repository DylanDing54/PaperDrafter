import Cocoa
import UniformTypeIdentifiers

extension App: NSMenuItemValidation {
    func menus() {
        let menu = NSMenu()
        func group(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title,action: nil,keyEquivalent: "")
            let m = NSMenu(title: title); item.submenu = m; menu.addItem(item); return m
        }
        @discardableResult func add(_ m: NSMenu,_ title: String,_ sel: Selector,_ key: String = "",_ modifiers: NSEvent.ModifierFlags = .command,_ target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title,action: sel,keyEquivalent: key)
            item.target = target; item.keyEquivalentModifierMask = modifiers; m.addItem(item); return item
        }
        let app = group("PaperDrafter")
        add(app,tr("关于 PaperDrafter","About PaperDrafter"),#selector(NSApplication.orderFrontStandardAboutPanel(_:)),"",.command,NSApp)
        let langs = NSMenuItem(title: "界面语言 / Language",action: nil,keyEquivalent: "")
        let lm = NSMenu(title: langs.title); langs.submenu = lm; app.addItem(langs)
        for (title,code) in [("简体中文","zh"),("English","en")] {
            let i = add(lm,title,#selector(language(_:)),"",.command,self); i.representedObject = code
            i.state = (useEnglish == (code == "en")) ? .on : .off
        }
        app.addItem(.separator()); add(app,tr("退出 PaperDrafter","Quit PaperDrafter"),#selector(NSApplication.terminate(_:)),"q",.command,NSApp)
        let projects = group(tr("项目","Projects"))
        add(projects,tr("项目库…","Project Library…"),#selector(showLibrary),"p",[.command,.shift],self)
        let f = group(tr("文件","File"))
        add(f,tr("新建工程…","New Project…"),#selector(newProject),"n",[.command,.shift],self)
        add(f,tr("打开工程文件夹…","Open Project Folder…"),#selector(openProject),"o",.command,self)
        add(f,tr("导入 Overleaf ZIP…","Import Overleaf ZIP…"),#selector(importZIP),"o",[.command,.shift],self)
        f.addItem(.separator())
        add(f,tr("新建文件…","New File…"),#selector(newFile),"n",.command,self)
        add(f,tr("保存","Save"),#selector(saveFile),"s",.command,self)
        add(f,tr("设为主文件","Set Current File as Main"),#selector(setMain),"",.command,self)
        add(f,tr("在访达中显示工程","Show Project in Finder"),#selector(reveal),"",.command,self)
        add(f,tr("导出 PDF…","Export PDF…"),#selector(exportPDF),"e",[.command,.shift],self)
        f.addItem(.separator()); add(f,tr("关闭窗口","Close Window"),#selector(NSWindow.performClose(_:)),"w")
        let edit = group(tr("编辑","Edit"))
        for (title,sel,key) in [(tr("撤销","Undo"),"undo:","z"),(tr("重做","Redo"),"redo:","Z"),(tr("剪切","Cut"),"cut:","x"),(tr("拷贝","Copy"),"copy:","c"),(tr("粘贴","Paste"),"paste:","v"),(tr("全选","Select All"),"selectAll:","a")] {
            add(edit,title,NSSelectorFromString(sel),key.lowercased(),key == "Z" ? [.command,.shift] : .command)
        }
        add(edit,tr("查找和替换…","Find and Replace…"),#selector(findText),"f",.command,self)
        let writing = group(tr("写作","Writing"))
        add(writing,tr("润色选区","Polish Selection"),#selector(polishSelection),"p",[.command,.option],self)
        let automatic = add(writing,tr("选中后自动建议","Suggest on Selection"),#selector(toggleAutomaticPolish(_:)),"",.command,self)
        automatic.state = prefs.bool(forKey: "disableAutomaticPolish") ? .off : .on
        let b = group(tr("编译","Build"))
        add(b,tr("编译工程","Compile Project"),#selector(compile),"\r",.command,self)
        add(b,tr("显示或隐藏日志","Toggle Build Log"),#selector(toggleLog),"l",[.command,.shift],self)
        NSApp.mainMenu = menu
    }
    @objc func language(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String, (code == "en") != useEnglish, flush() else { return }
        let folder = root?.url, current = draft?.url, document = ui.pdf.document, url = pdfURL, logText = ui.log.string
        let wasBusy = busy
        prefs.set(code,forKey: "interfaceLanguage")
        ui = WorkspaceUI(); ui.configure(self,window: window); menus()
        do {
            if let folder = folder { try load(folder); if let current = current { select(current) } }
            ui.pdf.document = document; pdfURL = url; ui.log.string = logText
            pageChanged(); update()
            if wasBusy || document != nil { compile() }
        } catch { show(error) }
    }
    @objc func findText() {
        window.makeFirstResponder(ui.editor)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        ui.editor.performTextFinderAction(item)
    }
    @objc func setMain() {
        guard let url = draft?.url, url.pathExtension.lowercased() == "tex", flush() else { return }
        main = url; prefs.set(relative(url),forKey: pref("main")); revision += 1
        buildStatus = tr("待编译","Needs build"); ui.outline.reloadData(); select(url); update()
    }
    @objc func reveal() { if let dir = root?.url { NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath: dir.path) } }
    @objc func refreshFiles() {
        guard let folder = root?.url, flush() else { return }
        let url = draft?.url
        root = Entry(folder,true); ui.outline.reloadData(); clearEditor()
        if let url = url, files.fileExists(atPath: url.path) { select(url) }
        update()
    }
    @objc func openProject() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true
        p.prompt = tr("打开工程","Open Project")
        guard p.runModal() == .OK,let url = p.url,flush() else { return }
        do { try load(url); compile() } catch { show(error) }
    }
    func destination(_ suggested: String, title: String) -> URL? {
        let panel = NSSavePanel(); panel.title = title; panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard !files.fileExists(atPath: url.path) else {
            show(Problem(tr("请选择一个新名称，以保留现有文件。","Choose a new name to preserve the existing files."))); return nil
        }
        return url
    }
    @objc func newProject() {
        guard flush(), let template = TemplatePicker().choose(),
              let dest = destination(template.projectName,title: tr("保存新工程","Save New Project")) else { return }
        do {
            try template.create(at: dest,resources: Bundle.main.resourceURL!)
            try load(dest)
            ui.engine.selectItem(withTitle: template.engine.rawValue); changeEngine()
            compile()
        } catch { show(error) }
    }
    @objc func newFile() {
        guard let root = root, flush() else { return }
        let p = NSSavePanel(); p.title = tr("在工程内新建文件","New File in Project")
        p.directoryURL = draft?.url.deletingLastPathComponent() ?? root.url; p.nameFieldStringValue = "section.tex"
        guard p.runModal() == .OK, let url = p.url else { return }
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == root.url.path ||
            url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.url.path + "/") else {
            show(Problem(tr("请选择工程内的位置。","Choose a location inside the project."))); return
        }
        do {
            try Data().write(to: url,options: .withoutOverwriting)
            refreshFiles(); select(url)
            if main == nil && url.pathExtension.lowercased() == "tex" { setMain() }
            window.makeFirstResponder(ui.editor)
        } catch { show(error) }
    }
    @objc func importZIP() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.zip]; p.prompt = tr("选择 ZIP","Select ZIP")
        guard p.runModal() == .OK, let archive = p.url, flush(),
              let dest = destination(archive.deletingPathExtension().lastPathComponent,title: tr("将工程解压到","Extract Project To")) else { return }
        do { let folder = try extractZIP(archive,to: dest); try load(folder); compile() } catch { show(error) }
    }
    func extractZIP(_ archive: URL,to dest: URL) throws -> URL {
        let stage = dest.deletingLastPathComponent().appendingPathComponent(".paperdrafter-import-" + UUID().uuidString)
        try files.createDirectory(at: stage,withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        let proc = Process(), pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [resource("import_zip.py").path,archive.path,stage.path]
        proc.standardError = pipe; proc.standardOutput = pipe; try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw Problem(String(decoding: data,as: UTF8.self)) }
        let content = try files.contentsOfDirectory(at: stage,includingPropertiesForKeys: [.isDirectoryKey],options: .skipsHiddenFiles)
        let wrapped = content.count == 1 && (try? content[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let nested = wrapped ? content[0].lastPathComponent : nil
        try files.moveItem(at: stage,to: dest)
        return nested.map { dest.appendingPathComponent($0) } ?? dest
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(compile): return main != nil && !busy
        case #selector(exportPDF): return pdfURL != nil
        case #selector(polishSelection): return draft != nil && ui.editor.selectedRange().length > 0 && ui.editor.selectedRange().length <= 6000
        case #selector(setMain): return draft?.url.pathExtension.lowercased() == "tex"
        default: return true
        }
    }
}

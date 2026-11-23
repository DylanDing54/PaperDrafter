import Cocoa
import PDFKit
import UniformTypeIdentifiers

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSSplitViewDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1320,height: 820),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
    lazy var links = SourceLinks(self)
    lazy var polish = PolishController(self)
    var ui = WorkspaceUI()
    var root: Entry?
    var main: URL?
    var draft: Draft?
    var dirty = false
    var busy = false
    var revision = 0
    var projectID = UUID()
    var autosave: Timer?
    var pdfURL: URL?
    var buildStatus = ""
    var sessionTemp = files.temporaryDirectory.appendingPathComponent("PaperDrafter-" + UUID().uuidString)
    var languagesMenu: NSMenu?
    static let syntax: [(NSRegularExpression, NSColor)] = [
        (#"\\(?:[A-Za-z@]+\*?|.)"#, violet),
        (#"[{}\[\]]"#, NSColor(srgbRed: 0.60,green: 0.38,blue: 0.16,alpha: 1)),
        (#"(?<!\\)%[^\r\n]*"#, NSColor(srgbRed: 0.27,green: 0.48,blue: 0.40,alpha: 1))
    ].compactMap { pattern,color in (try? NSRegularExpression(pattern: pattern)).map { ($0,color) } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProjectHistory.migrate()
        window.minSize = NSSize(width: 900,height: 550); window.title = "PaperDrafter"
        if let frame = NSScreen.main?.visibleFrame { window.setContentSize(NSSize(width: min(1320,frame.width-36),height: min(820,frame.height-60))) }
        window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        ui.configure(self,window: window); menus()
        NotificationCenter.default.addObserver(self,selector: #selector(pageChanged),name: .PDFViewPageChanged,object: nil)
        NotificationCenter.default.addObserver(self,selector: #selector(updateZoomStatus),name: .PDFViewScaleChanged,object: nil)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do {
            try ProjectHistory.migrateSample()
            let saved = prefs.string(forKey: "lastProject").map { URL(fileURLWithPath: $0) }
            if let saved = saved, (try? saved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try load(saved); compile()
            } else {
                let appData = try files.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent("PaperDrafter")
                try files.createDirectory(at: appData, withIntermediateDirectories: true)
                let sample = appData.appendingPathComponent("Research Notes")
                if !files.fileExists(atPath: sample.path) { try files.copyItem(at: resource("Sample"),to: sample) }
                try load(sample); compile()
            }
        } catch { show(error) }
    }
    func resource(_ name: String) -> URL { Bundle.main.resourceURL!.appendingPathComponent(name) }
    func show(_ error: Error) {
        let a = NSAlert(); a.messageText = tr("操作未完成","Action could not be completed")
        a.informativeText = error.localizedDescription; a.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { flush() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { flush() ? .terminateNow : .terminateCancel }
    func applicationWillTerminate(_ notification: Notification) { polish.cancel(); if !busy { try? files.removeItem(at: sessionTemp) } }
    func pref(_ key: String) -> String { key + "." + (root?.url.path ?? "") }
    func relative(_ u: URL) -> String { canonical(u).pathComponents.dropFirst(root?.url.pathComponents.count ?? 0).joined(separator: "/") }
    func load(_ url: URL) throws {
        let folder = canonical(url)
        _ = try files.contentsOfDirectory(atPath: folder.path)
        links.reset()
        root = Entry(folder,true); projectID = UUID(); busy = false; revision = 0
        autosave?.invalidate(); dirty = false; draft = nil; main = nil
        pdfURL = nil; ui.pdf.document = nil; ui.log.string = ""; ui.logPanel.isHidden = true
        ui.pdfHint.stringValue = tr("编译工程以预览 PDF","Compile the project to preview the PDF")
        ui.pdfHint.isHidden = false; ui.compileButton.isEnabled = true; buildStatus = ""
        let saved = prefs.string(forKey: pref("main")).map { folder.appendingPathComponent($0).standardizedFileURL }
        if let saved = saved, saved.path.hasPrefix(folder.path + "/"), files.fileExists(atPath: saved.path) { main = saved }
        if main == nil {
            let local = root!.children.filter { !$0.folder && $0.url.pathExtension.lowercased() == "tex" }
            main = local.first { $0.url.lastPathComponent == "main.tex" }?.url
            if main == nil {
                var candidates = local
                func collect(_ e: Entry) {
                    for f in e.children { if f.folder { collect(f) } else if f.url.pathExtension.lowercased() == "tex" { candidates.append(f) } }
                }
                for child in root!.children where child.folder { collect(child) }
                main = candidates.first { e in
                    guard let source = try? String(contentsOf: e.url, encoding: .utf8) else { return false }
                    return source.range(of: #"(?m)^\s*\\documentclass\b"#,options: .regularExpression) != nil
                }?.url ?? candidates.first?.url
            }
        }
        let engine = prefs.string(forKey: pref("engine")) ?? Engine.tectonic.rawValue
        ui.engine.selectItem(withTitle: engine)
        ProjectHistory.record(folder)
        prefs.set(folder.path,forKey: "lastProject")
        ui.outline.reloadData(); clearEditor()
        if let main = main { select(main) }
        update(); pageChanged()
    }
    func clearEditor() {
        polish.cancel()
        draft = nil; dirty = false; ui.ruler?.lines = SourceLines(""); links.refreshRuler(); ui.editor.string = ""; ui.editor.isEditable = false
        ui.editor.undoManager?.removeAllActions(); ui.fileName.stringValue = "—"
    }
    func update() {
        ui.projectName.stringValue = root?.url.lastPathComponent ?? "PaperDrafter"
        ui.mainName.stringValue = main.map { " / " + relative($0) } ?? ""
        window.title = ui.projectName.stringValue + " — PaperDrafter"
        window.isDocumentEdited = dirty; ui.status.stringValue = dirty ? tr("未保存","Unsaved") : buildStatus
        ui.compileButton.isEnabled = !busy && main != nil
        ui.pdfHint.isHidden = ui.pdf.document != nil
        updateCaret()
    }
    func select(_ url: URL) {
        guard let root = root else { return }
        let url = canonical(url)
        func descend(_ parent: Entry) {
            for e in parent.children {
                if e.url.standardizedFileURL.path == url.standardizedFileURL.path {
                    let row = ui.outline.row(forItem: e)
                    if row >= 0 {
                        ui.outline.selectRowIndexes(IndexSet(integer: row),byExtendingSelection: false)
                        ui.outline.scrollRowToVisible(row)
                    }
                    return
                }
                if e.folder && url.path.hasPrefix(e.url.path + "/") { ui.outline.expandItem(e); descend(e); return }
            }
        }
        descend(root)
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? Entry) ?? root)?.children.count ?? 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Entry) ?? root)!.children[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Entry)?.folder == true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let e = item as? Entry else { return nil }
        let v = NSTableCellView()
        let symbol = e.folder ? "folder" : (e.url == main ? "doc.text.fill" : (e.editable ? "doc.text" : "doc"))
        let i = NSImageView(image: icon(symbol) ?? NSImage()); i.contentTintColor = e.url == main ? .init(srgbRed: 0.80,green: 0.73,blue: 1,alpha: 1) : .init(white: 0.73,alpha: 1)
        let name = label(e.url.lastPathComponent,12,.regular,.init(white: 0.92,alpha: 1))
        let row = stack([i,name,spacer()],gap: 7); embed(row,in: v); v.textField = name
        i.widthAnchor.constraint(equalToConstant: 15).isActive = true
        return v
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let e = item as? Entry else { return false }
        return !e.folder && flush()
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let e = ui.outline.item(atRow: ui.outline.selectedRow) as? Entry, !e.folder else { return }
        if draft?.url == e.url { return }
        autosave?.invalidate(); clearEditor()
        do {
            ui.fileName.stringValue = e.url.lastPathComponent
            if e.editable {
                let d = try Draft(e.url); draft = d; ui.editor.string = d.text; ui.editor.isEditable = true
                ui.editor.setSelectedRange(NSRange(location: 0,length: 0)); ui.editor.scrollRangeToVisible(.init(location: 0,length: 0))
                highlight(); ui.editor.undoManager?.removeAllActions()
            } else {
                ui.editor.string = tr("资源文件","Project asset") + "\n\n" + relative(e.url)
            }
        } catch { show(error) }
        update()
    }
    func highlight() {
        guard let manager = ui.editor.layoutManager else { return }
        let text = ui.editor.string, range = NSRange(location: 0,length: (text as NSString).length)
        manager.removeTemporaryAttribute(.foregroundColor,forCharacterRange: range)
        if range.length <= 350000 {
            for (pattern,color) in Self.syntax {
                pattern.enumerateMatches(in: text,range: range) { match,_,_ in
                    if let m = match { manager.addTemporaryAttribute(.foregroundColor,value: color,forCharacterRange: m.range) }
                }
            }
        }
        ui.ruler?.lines = SourceLines(text as NSString); links.refreshRuler()
        if let ruler = ui.ruler { window.invalidateCursorRects(for:ruler) }
    }
    func textDidChange(_ notification: Notification) {
        guard draft != nil else { return }
        links.clear(); polish.cancel(); dirty = true; revision += 1
        buildStatus = tr("待编译","Needs build")
        if !ui.editor.hasMarkedText() { highlight() }
        update(); autosave?.invalidate()
        autosave = Timer.scheduledTimer(withTimeInterval: 0.85,repeats: false) { [weak self] _ in
            guard let self = self, !self.ui.editor.hasMarkedText() else { return }
            _ = self.flush(interactive: false)
        }
    }
    func updateCaret() {
        let text = ui.editor.string as NSString, p = min(ui.editor.selectedRange().location,text.length)
        let prefix = text.substring(to: p)
        let line = prefix.reduce(1) { $0 + ($1.isNewline ? 1 : 0) }
        let col = (prefix.split(omittingEmptySubsequences: false,whereSeparator: { $0.isNewline }).last?.count ?? 0) + 1
        ui.caret.stringValue = draft == nil ? "" : tr("行 \(line)  ·  列 \(col)","Ln \(line)  ·  Col \(col)")
    }
    func textViewDidChangeSelection(_ notification: Notification) { updateCaret(); polish.selectionChanged() }

    @discardableResult func flush(interactive: Bool = true) -> Bool {
        guard dirty, var d = draft else { return true }
        if interactive && ui.editor.hasMarkedText() { ui.editor.unmarkText() }
        do {
            if (try? Data(contentsOf: d.url)) != d.original {
                guard interactive else { ui.status.stringValue = tr("磁盘文件已更改","File changed on disk"); return false }
                let a = NSAlert(); a.messageText = tr("磁盘上的文件已更改","The file changed on disk")
                a.informativeText = d.url.path
                a.addButton(withTitle: tr("取消","Cancel")); a.addButton(withTitle: tr("用编辑内容覆盖","Overwrite with editor text")); a.addButton(withTitle: tr("载入磁盘版本","Reload disk version"))
                switch a.runModal() {
                case .alertSecondButtonReturn: try d.save(ui.editor.string,replace: true)
                case .alertThirdButtonReturn:
                    links.clear(); revision += 1
                    d = try Draft(d.url); ui.editor.string = d.text; ui.editor.undoManager?.removeAllActions(); highlight()
                default: return false
                }
            } else { try d.save(ui.editor.string) }
            draft = d; dirty = false; update(); return true
        } catch {
            if interactive { show(error) } else { ui.status.stringValue = tr("保存失败 · 请按 ⌘S","Save failed · Press ⌘S") }
            return false
        }
    }
    @objc func saveFile() { _ = flush() }
    @objc func compile() {
        guard !busy, let root = root?.url, let main = main, flush() else { return }
        let id = projectID, version = revision
        let engine = Engine(rawValue: ui.engine.titleOfSelectedItem ?? "") ?? .tectonic
        let output = sessionTemp.appendingPathComponent(UUID().uuidString)
        busy = true; buildStatus = tr("正在编译…","Compiling…"); ui.log.string = buildStatus; update()
        let syncTool = resource("Tools/synctex")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Compiler.run(root: root, main: main, engine: engine, output: output) }
            let map = (try? result.get())?.pdf.flatMap { SyncMap(pdf:$0,root:root,main:main,tool:syncTool) }
            DispatchQueue.main.async {
                guard self.projectID == id else { try? files.removeItem(at: output); return }
                self.busy = false
                let report: BuildResult
                switch result {
                case .success(let r): report = r
                case .failure(let e): report = BuildResult(log: e.localizedDescription,pdf: nil)
                }
                self.ui.log.string = report.log
                if let url = report.pdf, let doc = PDFDocument(url: url) {
                    let previous = self.pdfURL?.deletingLastPathComponent()
                    let index = self.ui.pdf.currentPage.flatMap { self.ui.pdf.document?.index(for: $0) } ?? 0
                    self.pdfURL = url; self.ui.pdf.document = doc
                    if index > 0, let page = doc.page(at: min(index,doc.pageCount-1)) { self.ui.pdf.go(to: page) }
                    self.links.installed(map,revision:version)
                    if previous != output, let previous = previous { try? files.removeItem(at: previous) }
                    self.buildStatus = self.revision == version ? tr("编译成功","Build succeeded") : tr("待编译","Needs build")
                } else {
                    self.links.failedBuild()
                    self.buildStatus = tr("编译失败","Build failed"); self.ui.logPanel.isHidden = false
                    try? files.removeItem(at: output)
                }
                self.update(); self.pageChanged()
            }
        }
    }
    @objc func changeEngine() {
        if let name = ui.engine.titleOfSelectedItem { prefs.set(name,forKey: pref("engine")); revision += 1; buildStatus = tr("待编译","Needs build"); update() }
    }
    @objc func toggleLog() { ui.logPanel.isHidden.toggle() }
    @objc func pageChanged() {
        updateZoomStatus()
        guard let d = ui.pdf.document, let p = ui.pdf.currentPage else { ui.pdfPages.stringValue = "—"; return }
        ui.pdfPages.stringValue = tr("第 \(d.index(for:p)+1) 页 / 共 \(d.pageCount) 页","Page \(d.index(for:p)+1) of \(d.pageCount)")
    }
    @objc func updateZoomStatus() {
        let pdf = ui.pdf
        ui.fitButton.isEnabled = pdf.document != nil
        guard pdf.document != nil else { ui.zoomStatus.stringValue = ""; return }
        let width = pdf.autoScales && pdf.displayMode == .singlePageContinuous
        let mode: String
        if !pdf.autoScales { mode = tr("手动缩放","Manual zoom") }
        else { mode = width ? tr("适合页宽","Page width") : tr("完整页面","Whole page") }
        ui.zoomStatus.stringValue = "\(mode) · \(Int((pdf.scaleFactor * 100).rounded()))%"
        let next = width ? tr("切换到完整页面","Switch to whole page") : tr("切换到适合页宽","Switch to page width")
        ui.fitButton.toolTip = next; ui.fitButton.setAccessibilityLabel(next)
    }
    @objc func zoomOut() {
        guard ui.pdf.canZoomOut else { return }
        ui.pdf.autoScales = false; ui.pdf.zoomOut(nil); updateZoomStatus()
    }
    @objc func zoomIn() {
        guard ui.pdf.canZoomIn else { return }
        ui.pdf.autoScales = false; ui.pdf.zoomIn(nil); updateZoomStatus()
    }
    @objc func fitPDF() {
        let pdf = ui.pdf
        guard let page = pdf.currentPage else { return }
        let whole = pdf.autoScales && pdf.displayMode == .singlePageContinuous
        pdf.displayMode = whole ? .singlePage : .singlePageContinuous
        pdf.autoScales = true
        pdf.go(to: page)
        updateZoomStatus()
    }
    @objc func exportPDF() {
        guard let url = pdfURL else { NSSound.beep(); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent; panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let target = panel.url {
            do { try Data(contentsOf: url).write(to: target,options: .atomic) } catch { show(error) }
        }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? 145 : splitView.subviews[0].frame.maxX + 240
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? min(380,splitView.subviews[1].frame.maxX-240) : splitView.bounds.width - 240
    }
}

import Cocoa

enum ProjectHistory {
    static func migrate() {
        guard !prefs.bool(forKey: "importedInkTeXHistory") else { return }
        let old = prefs.persistentDomain(forName: "local.inktex.editor") ?? [:]
        for (key, value) in old where ["interfaceLanguage","lastProject"].contains(key) || key.hasPrefix("main.") || key.hasPrefix("engine.") {
            if prefs.object(forKey: key) == nil { prefs.set(value, forKey: key) }
        }
        prefs.set(true, forKey: "importedInkTeXHistory")
    }
    static func migrateSample() throws {
        guard prefs.string(forKey: "migratedSamplePath") == nil else { return }
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let legacy = support.appendingPathComponent("InkTeX/Research Notes")
        guard files.fileExists(atPath: legacy.path) else { return }
        let parent = support.appendingPathComponent("PaperDrafter")
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        var dest = parent.appendingPathComponent("Research Notes")
        var suffix = 1
        while files.fileExists(atPath: dest.path) {
            suffix += 1
            dest = parent.appendingPathComponent("Research Notes (\(suffix))")
        }
        let stage = parent.appendingPathComponent(".sample-" + UUID().uuidString)
        defer { try? files.removeItem(at: stage) }
        try files.copyItem(at: legacy, to: stage)
        let main = stage.appendingPathComponent("main.tex")
        if (try? main.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
           let data = try? Data(contentsOf: main), let text = String(data: data, encoding: .utf8) {
            let revised = text.replacingOccurrences(of: #"(?m)^% 墨页 · 研究笔记(?=\r?$)"#,
                                                     with: "% PaperDrafter · 研究笔记", options: .regularExpression)
                              .replacingOccurrences(of: #"{\small 墨页编辑室\quad / \quad 工作笔记}\par"#,
                                                     with: #"{\small PaperDrafter\quad / \quad 工作笔记}\par"#)
            if revised != text { try Data(revised.utf8).write(to: main, options: .atomic) }
        }
        try files.moveItem(at: stage, to: dest)
        for prefix in ["main.","engine."] {
            if let value = prefs.object(forKey: prefix + legacy.path) {
                prefs.set(value, forKey: prefix + dest.path); prefs.removeObject(forKey: prefix + legacy.path)
            }
        }
        if prefs.string(forKey: "lastProject") == legacy.path { prefs.set(dest.path, forKey: "lastProject") }
        if let recent = prefs.stringArray(forKey: "recentProjectPaths") {
            prefs.set(recent.map { $0 == legacy.path ? dest.path : $0 }, forKey: "recentProjectPaths")
        }
        prefs.set(dest.path, forKey: "migratedSamplePath")
    }
    static func record(_ url: URL) {
        let path = canonical(url).path
        var recent = prefs.stringArray(forKey: "recentProjectPaths") ?? []
        recent.removeAll { $0 == path }; recent.insert(path, at: 0)
        prefs.set(recent, forKey: "recentProjectPaths")
    }
    static func discover() -> [String] {
        let home = files.homeDirectoryForCurrentUser
        var candidates = prefs.stringArray(forKey: "recentProjectPaths") ?? []
        if let last = prefs.string(forKey: "lastProject") { candidates.append(last) }
        for k in prefs.dictionaryRepresentation().keys where k.hasPrefix("main./") || k.hasPrefix("engine./") {
            if let split = k.firstIndex(of: ".") { candidates.append(String(k[k.index(after: split)...])) }
        }
        candidates.append(home.appendingPathComponent("Library/Application Support/PaperDrafter/Research Notes").path)
        if let migrated = prefs.string(forKey: "migratedSamplePath") { candidates.append(migrated) }
        let workspace = home.appendingPathComponent("Documents/Work/Topic/TSP")
        let ignored: Set<String> = ["tmp","node_modules","build","dist","target","vendor","PaperDrafter","InkTeX","__pycache__"]
        let keys: [URLResourceKey] = [.isDirectoryKey,.isSymbolicLinkKey]
        var discovered = Set<String>()
        if let walk = files.enumerator(at: workspace,includingPropertiesForKeys: keys, options: [.skipsHiddenFiles,.skipsPackageDescendants]) {
            for case let url as URL in walk {
                if ignored.contains(url.lastPathComponent) || url.pathExtension == "app" { walk.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "tex", let f = try? FileHandle(forReadingFrom: url) else { continue }
                let header = String(decoding: f.readData(ofLength: 32768),as: UTF8.self); try? f.close()
                if header.range(of: #"(?m)^\s*\\documentclass\b"#,options: .regularExpression) != nil {
                    discovered.insert(url.deletingLastPathComponent().path)
                }
            }
        }
        candidates += discovered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var seen = Set<String>()
        return candidates.compactMap {
            let url = canonical(URL(fileURLWithPath: $0))
            guard seen.insert(url.path).inserted, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url.path
        }
    }
}

final class LibraryPage: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    unowned let app: App
    let search = NSSearchField()
    let table = NSTableView()
    let count = label("",11,.regular,muted)
    let openButton = NSButton()
    var paths = [String]()
    var filtered = [String]()
    init(_ app: App) { self.app = app; super.init(nibName: nil,bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0,y: 0,width: 650,height: 450))
        let heading = label(tr("项目库","Project Library"),25,.bold)
        search.placeholderString = tr("搜索项目名称或路径","Search by project name or path"); search.delegate = self
        let col = NSTableColumn(identifier: .init("project")); table.addTableColumn(col); table.headerView = nil
        table.rowHeight = 54; table.dataSource = self; table.delegate = self; table.target = self
        table.doubleAction = #selector(openSelected); table.style = .inset
        let scroller = NSScrollView(); scroller.documentView = table; scroller.hasVerticalScroller = true
        scroller.borderType = .bezelBorder
        let close = action(tr("返回编辑器","Back to editor"),"chevron.left",self,#selector(dismissPage))
        let browse = action(tr("打开其他工程…","Open other project…"),"folder",self,#selector(browseFolder))
        openButton.title = tr("打开所选项目","Open selected project"); openButton.target = self
        openButton.action = #selector(openSelected); openButton.bezelStyle = .rounded; openButton.bezelColor = violet
        let header = bar([heading,spacer(),count],height: 54,inset: 0)
        let bottom = bar([close,spacer(),browse,openButton],height: 48,inset: 0)
        embed(pane([header,search,scroller,bottom]),in: view,inset: 20)
        count.stringValue = tr("正在查找…","Finding projects…")
        openButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = ProjectHistory.discover()
            DispatchQueue.main.async { self?.paths = list; self?.filter() }
        }
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func filter() {
        filtered = paths.filter { search.stringValue.isEmpty || $0.localizedCaseInsensitiveContains(search.stringValue) }
        count.stringValue = tr("\(filtered.count) 个项目","\(filtered.count) projects")
        table.reloadData(); if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0),byExtendingSelection: false) }
        openButton.isEnabled = table.selectedRow >= 0
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableViewSelectionDidChange(_ notification: Notification) { openButton.isEnabled = table.selectedRow >= 0 }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let path = filtered[row], url = URL(fileURLWithPath: path)
        let title = label(url.lastPathComponent,14,.semibold)
        let detail = label((path as NSString).abbreviatingWithTildeInPath,11,.regular,muted)
        detail.lineBreakMode = .byTruncatingMiddle
        let glyph = NSImageView(image: icon("folder") ?? NSImage()); glyph.contentTintColor = violet
        let rowView = NSView(); embed(stack([glyph,stack([title,detail],vertical: true,gap: 3),spacer()],gap: 10),in: rowView,inset: 4)
        rowView.toolTip = path; return rowView
    }
    @objc func dismissPage() { if let w = view.window { app.window.endSheet(w) } }
    @objc func openSelected() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let url = URL(fileURLWithPath: filtered[table.selectedRow])
        dismissPage()
        guard app.flush() else { return }
        if canonical(url) == app.root?.url { return }
        do { try app.load(url); app.compile() } catch { app.show(error) }
    }
    @objc func browseFolder() { dismissPage(); app.openProject() }
}
extension App {
    @objc func showLibrary() {
        guard window.attachedSheet == nil else { return }
        polish.cancel()
        let page = LibraryPage(self)
        let panel = NSPanel(contentViewController: page); panel.title = tr("项目库","Project Library")
        panel.styleMask = [.titled,.resizable]; panel.minSize = NSSize(width: 510,height: 320)
        panel.setContentSize(NSSize(width: 650,height: 450))
        window.beginSheet(panel) { _ in panel.orderOut(nil) }
    }
}

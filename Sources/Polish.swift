import Cocoa

private struct Excerpt: Equatable {
    let project: UUID
    let file: URL
    let revision: Int
    let range: NSRange
    let text: String
}

final class SuggestionView: NSViewController {
    let bodyText = NSTextView()
    let position = label("",11,.medium,violet)
    let accept = NSButton()
    let reference = NSButton()
    let retry = NSButton()
    let heading = label(tr("润色建议","Writing suggestion"),15,.semibold)
    var acceptAction: (() -> Void)?
    var retryAction: (() -> Void)?
    var closeAction: (() -> Void)?
    private var examples: [String] = []
    private var suggestion = ""
    private var showingExamples = false
    override func loadView() {
        view = NSView(frame: NSRect(x: 0,y: 0,width: 395,height: 225))
        let close = action("", "xmark", self, #selector(closePanel)); close.isBordered = false
        close.toolTip = tr("关闭","Close")
        let title = bar([heading,spacer(),close],height: 34,inset: 0)
        bodyText.isEditable = false; bodyText.isSelectable = true; bodyText.drawsBackground = false
        bodyText.font = .systemFont(ofSize: 14); bodyText.textContainerInset = NSSize(width: 0,height: 5)
        bodyText.isHorizontallyResizable = false; bodyText.autoresizingMask = [.width]
        bodyText.string = tr("正在润色…","Polishing…")
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = bodyText
        for button in [accept,reference,retry] { button.target = self; button.bezelStyle = .rounded }
        accept.title = tr("采用","Apply"); accept.action = #selector(apply); accept.bezelColor = violet; accept.isEnabled = false
        retry.title = tr("重试","Retry"); retry.action = #selector(tryAgain); retry.isHidden = true
        reference.action = #selector(toggleExamples); reference.isHidden = true
        position.toolTip = tr("句库检索位置","Corpus lookup position")
        embed(pane([title,position,line(),scroll,bar([reference,spacer(),retry,accept],height: 35,inset: 0)]),in: view,inset: 12)
    }
    func display(_ text: String, examples: [String], position context: String) {
        position.stringValue = context; position.toolTip = context
        suggestion = text; self.examples = examples
        bodyText.string = text; accept.isEnabled = true
        reference.title = tr("本地例句","Local examples") + " (\(examples.count))"
        reference.isHidden = examples.isEmpty
    }
    func failed(_ message: String) {
        bodyText.string = message; retry.isHidden = false; accept.isEnabled = false
    }
    @objc func toggleExamples() {
        showingExamples.toggle()
        bodyText.string = showingExamples ? examples.joined(separator: "\n\n") : suggestion
        reference.title = showingExamples ? tr("返回建议","Show suggestion") : tr("本地例句","Local examples") + " (\(examples.count))"
        accept.isHidden = showingExamples
        bodyText.scrollRangeToVisible(NSRange(location: 0,length: 0))
    }
    @objc func closePanel() { closeAction?() }
    @objc func apply() { acceptAction?() }
    @objc func tryAgain() { retryAction?() }
}

final class PolishController: NSObject, NSPopoverDelegate {
    unowned let app: App
    private var timer: Timer?
    private var process: Process?
    private var popover: NSPopover?
    private var snapshot: Excerpt?
    private var generation = UUID()
    init(_ app: App) { self.app = app }
    private func selection() -> Excerpt? {
        let editor = app.ui.editor, range = editor.selectedRange()
        guard editor.isEditable, !editor.hasMarkedText(), let file = app.draft?.url,
              range.length > 0, range.length <= 6000, NSMaxRange(range) <= (editor.string as NSString).length else { return nil }
        let text = (editor.string as NSString).substring(with: range)
        guard text.rangeOfCharacter(from: .letters) != nil else { return nil }
        return Excerpt(project: app.projectID,file: file,revision: app.revision,range: range,text: text)
    }
    func cancel() {
        generation = UUID(); snapshot = nil
        timer?.invalidate(); timer = nil
        if let process = process, process.isRunning { process.terminate() }; process = nil
        if let popover = popover { self.popover = nil; popover.delegate = nil; popover.close() }
    }
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        cancel()
    }
    func selectionChanged(manual: Bool = false) {
        let next = selection()
        if !manual && next == snapshot { return }
        cancel()
        guard let excerpt = next, app.window.attachedSheet == nil else { return }
        guard manual || !prefs.bool(forKey: "disableAutomaticPolish") else { return }
        guard manual || excerpt.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { return }
        snapshot = excerpt
        if manual { start(excerpt); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.65,repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            timer.invalidate()
            if let self = self, self.snapshot == excerpt, self.selection() == excerpt { self.start(excerpt) }
        }
    }
    private func start(_ excerpt: Excerpt) {
        let editor = app.ui.editor, view = SuggestionView(), panel = NSPopover()
        let id = generation
        panel.contentViewController = view; panel.contentSize = NSSize(width: 395,height: 225)
        panel.behavior = .transient; panel.animates = false; panel.delegate = self
        let screen = editor.firstRect(forCharacterRange: NSRange(location: excerpt.range.location,length: 1),actualRange: nil)
        let anchor = editor.convert(app.window.convertFromScreen(screen),from: nil)
        guard editor.visibleRect.intersects(anchor.insetBy(dx: -1,dy: -1)) else { cancel(); return }
        popover = panel
        view.closeAction = { [weak self] in self?.cancel() }
        view.retryAction = { [weak self] in self?.selectionChanged(manual: true) }
        panel.show(relativeTo: anchor,of: editor,preferredEdge: .maxY)
        let input: [String:Any] = ["text":excerpt.text,"source":editor.string,"offset":excerpt.range.location,
                                   "file":excerpt.file.path,"root":app.root?.url.path ?? "",
                                   "main":app.main?.path ?? excerpt.file.path]
        let proc = Process(), stdin = Pipe(), stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); proc.arguments = ["-B",app.resource("polish.py").path]
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = FileHandle.nullDevice
        do {
            let bytes = try JSONSerialization.data(withJSONObject: input)
            try proc.run(); process = proc
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: bytes); try? stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any]
                DispatchQueue.main.async { [weak self,weak view] in
                    guard let self = self, let view = view, self.generation == id else { return }
                    self.process = nil
                    guard self.selection() == excerpt else { self.cancel(); return }
                    guard proc.terminationStatus == 0, let text = reply?["suggestion"] as? String else {
                        view.failed(self.message(for: reply?["error"] as? String)); return
                    }
                    let examples = (reply?["examples"] as? [[String:String]] ?? []).compactMap { row -> String? in
                        guard let quote = row["text"] else { return nil }
                        return quote + "\n" + (row["source"] ?? "")
                    }
                    view.display(text,examples: examples,position: self.positionLabel(reply ?? [:]))
                    view.acceptAction = { [weak self] in
                        guard let self = self, self.generation == id, self.selection() == excerpt else { return }
                        self.cancel(); self.app.window.makeFirstResponder(editor)
                        editor.insertText(text,replacementRange: excerpt.range)
                    }
                }
            }
        } catch { view.failed(error.localizedDescription) }
    }
    private func positionLabel(_ reply: [String:Any]) -> String {
        guard let info = reply["location"] as? [String:Any] else { return "" }
        let names = ["abstract":"摘要","introduction":"引言","related":"相关工作","methodology":"实验方法",
                     "evaluation":"评估与结果","problem":"问题与模型","background":"背景与动机","overview":"方案概览",
                     "implementation":"实现","discussion":"讨论","conclusion":"结论","design":"设计与方法","other":"未分类"]
        let role = reply["role"] as? String ?? "other"
        let title = (info["headings"] as? [String] ?? []).joined(separator: " › ")
        let part = info["paragraph"] as? Int ?? 1
        let place = info["placement"] as? String ?? ""
        let positions = ["opening":"段首","middle":"段中","closing":"段末","standalone":"独句段"]
        let bucket = tr(names[role] ?? role,role.capitalized)
        let move = reply["move"] as? String ?? "other"
        let moves = ["gap":"研究缺口","motivation":"研究动机","contribution":"贡献","mechanism":"机制",
                     "setup":"实验设置","comparison":"对比","result":"结果","limitation":"局限","summary":"小结"]
        let purpose = moves[move].map { tr($0,move.capitalized) } ?? ""
        return [title,bucket,tr("第 \(part) 段","¶\(part)"),tr(positions[place] ?? "",place),purpose].filter { !$0.isEmpty }.joined(separator:" · ")
    }
    private func message(for error: String?) -> String {
        switch error {
        case "missing_dsh": return tr("找不到 DeepSeek Harness。请安装或打开 DSH 后重试。","DeepSeek Harness was not found. Install DSH and retry.")
        case "auth": return tr("模型认证失败。请检查 DSH 的模型凭据。","Authentication failed. Check the model credentials in DSH.")
        case "profile","choose_deepseek": return tr("请在 DSH 桌面端选择可用的 DeepSeek 模型后重试。","Select an available DeepSeek model in DSH and retry.")
        case "timeout","network": return tr("模型连接超时或不可达，请稍后重试。","The model timed out or is unreachable. Please retry.")
        case "latex": return tr("候选建议改变了 LaTeX 标记，请重试。","The candidates changed a LaTeX token. Please retry.")
        default: return tr("未收到可用的润色建议，请重试或检查 DSH。","No usable suggestion arrived. Retry or check DSH.")
        }
    }
}
extension App {
    @objc func polishSelection() { polish.selectionChanged(manual: true) }
    @objc func toggleAutomaticPolish(_ sender: NSMenuItem) {
        let disabled = !prefs.bool(forKey: "disableAutomaticPolish")
        prefs.set(disabled,forKey: "disableAutomaticPolish")
        sender.state = disabled ? .off : .on
        if disabled { polish.cancel() } else { polish.selectionChanged() }
    }
}

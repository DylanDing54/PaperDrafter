import Cocoa
import PDFKit

let violet = NSColor(srgbRed: 0.36, green: 0.29, blue: 0.62, alpha: 1)
let sidebarColor = NSColor(srgbRed: 0.15, green: 0.14, blue: 0.20, alpha: 1)
let muted = NSColor.secondaryLabelColor
func label(_ title: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
    let v = NSTextField(labelWithString: title)
    v.font = .systemFont(ofSize: size, weight: weight); v.textColor = color
    v.lineBreakMode = .byTruncatingTail
    return v
}
func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
func action(_ title: String, _ symbol: String, _ target: AnyObject, _ selector: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: selector)
    b.image = icon(symbol); b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    b.bezelStyle = .rounded; b.toolTip = title
    return b
}
func box(_ color: NSColor) -> NSView {
    let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = color.cgColor
    return v
}
func stack(_ views: [NSView], vertical: Bool = false, gap: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal
    s.spacing = gap; s.alignment = vertical ? .leading : .centerY
    return s
}
func embed(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}
func bar(_ views: [NSView], height: CGFloat, inset: CGFloat = 14) -> NSView {
    let v = NSView(), row = stack(views)
    v.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: inset),
        row.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -inset), row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        v.heightAnchor.constraint(equalToConstant: height)])
    return v
}
func spacer() -> NSView {
    let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal); return v
}
func pane(_ views: [NSView]) -> NSView {
    let s = stack(views, vertical: true, gap: 0)
    for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
    return s
}
func line() -> NSView {
    let v = box(NSColor(calibratedWhite: 0.87, alpha: 1)); v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
}

final class LineNumbers: NSRulerView {
    weak var source: NSTextView?
    init(scroll: NSScrollView, source: NSTextView) {
        super.init(scrollView: scroll, orientation: .verticalRuler)
        self.source = source; clientView = source; ruleThickness = 42
    }
    required init(coder: NSCoder) { fatalError() }
    var lines = SourceLines("")
    var selected = Set<Int>() { didSet { needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    private func visibleRows() -> [(Int,CGRect)] {
        var rows = [(Int,CGRect)]()
        guard let t = source, let manager = t.layoutManager, let container = t.textContainer else { return [] }
        let origin = t.textContainerOrigin
        let visible = manager.glyphRange(forBoundingRect:t.visibleRect.offsetBy(dx:-origin.x,dy:-origin.y),in:container)
        func row(_ number:Int,_ fragment:CGRect) {
            let rect = convert(fragment.offsetBy(dx:origin.x,dy:origin.y),from:t)
            rows.append((number,CGRect(x:0,y:rect.minY,width:ruleThickness,height:rect.height)))
        }
        manager.enumerateLineFragments(forGlyphRange:visible) { fragment,_,_,range,_ in
            let index = manager.characterIndexForGlyph(at:range.location)
            let number = self.lines.number(at:index)
            if self.lines.range(number)?.location == index { row(number,fragment) }
        }
        if manager.extraLineFragmentTextContainer != nil { row(lines.starts.count,manager.extraLineFragmentRect) }
        return rows
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        // NSRulerView installs a private content view over the badges.
        super.hitTest(point) == nil ? nil : self
    }
    override func mouseDown(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let (number,_) = visibleRows().first(where: { $0.1.contains(point) }) { onClick?(number) }
    }
    override func resetCursorRects() {
        super.resetCursorRects(); for (_,rect) in visibleRows() { addCursorRect(rect,cursor:.pointingHand) }
    }
    override func drawHashMarksAndLabels(in rect:NSRect) {
        NSColor(calibratedWhite:0.984,alpha:1).setFill(); bounds.fill()
        for (number,row) in visibleRows() {
            let active = selected.contains(number)
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.medium),
                .foregroundColor:active ? NSColor.white : NSColor.secondaryLabelColor]
            let digits = "\(number)" as NSString, size = digits.size(withAttributes:attrs)
            let side = min(19,max(size.height,row.height-1)), width = max(side,size.width+5)
            let badge = CGRect(x:ruleThickness-width-6,y:row.midY-side/2,width:width,height:side)
            (active ? sidebarColor : NSColor(calibratedWhite:0.94,alpha:1)).setFill()
            NSBezierPath(roundedRect:badge,xRadius:4,yRadius:4).fill()
            digits.draw(at:NSPoint(x:badge.midX-size.width/2,y:badge.midY-size.height/2),withAttributes:attrs)
        }
    }
}

final class WorkspaceUI {
    let projectName = label("", 14, .semibold)
    let fileName = label("", 13, .medium)
    let mainName = label("", 11, .regular, muted)
    let status = label("", 11, .medium, muted)
    let caret = label("", 11, .regular, muted)
    let zoomStatus = label("",11,.regular,muted)
    let fitButton = NSButton()
    let pdfPages = label("—", 11, .medium, muted)
    let compileButton = NSButton()
    let outline = NSOutlineView()
    let editor = NSTextView()
    let pdf = LinkedPDFView()
    let pdfHint = label("", 13, .medium, muted)
    let log = NSTextView()
    let logPanel = NSView()
    let split = NSSplitView()
    let engine = NSPopUpButton()
    let editorScroll = NSScrollView()
    let sidebar = NSView()
    var ruler: LineNumbers?
    func configure(_ app: App, window: NSWindow) {
        window.appearance = NSAppearance(named: .aqua)
        let brand = label("PaperDrafter", 21, .bold, .white)
        brand.font = NSFont(name: "Georgia-Bold", size: 20) ?? brand.font
        let sideTitle = bar([brand, spacer()], height: 58, inset: 15)
        let library = action(tr("项目库","Project Library"), "books.vertical", app, #selector(App.showLibrary))
        library.isBordered = false
        let add = action("", "plus", app, #selector(App.newFile))
        add.toolTip = tr("新建文件","New file"); add.isBordered = false
        let refresh = action("", "arrow.clockwise", app, #selector(App.refreshFiles))
        refresh.isBordered = false; refresh.toolTip = tr("刷新文件树","Refresh files")
        let heading = bar([label(tr("工程文件","PROJECT FILES"), 11, .semibold, .init(white: 0.73, alpha: 1)), spacer(), refresh, add], height: 38)
        let treeScroll = NSScrollView()
        treeScroll.hasVerticalScroller = true; treeScroll.autohidesScrollers = true; treeScroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("files"))
        outline.addTableColumn(col); outline.outlineTableColumn = col; outline.headerView = nil
        outline.dataSource = app; outline.delegate = app; outline.rowHeight = 29; outline.indentationPerLevel = 10
        outline.backgroundColor = sidebarColor; outline.floatsGroupRows = false
        outline.style = .sourceList; outline.selectionHighlightStyle = .regular
        treeScroll.documentView = outline
        let open = action(tr("打开工程…","Open project…"), "folder", app, #selector(App.openProject))
        let new = action(tr("新建工程…","New project…"), "square.and.pencil", app, #selector(App.newProject))
        open.isBordered = false; new.isBordered = false
        sidebar.appearance = NSAppearance(named: .darkAqua)
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = sidebarColor.cgColor
        embed(pane([sideTitle,bar([library,spacer()],height: 34),heading,treeScroll,bar([new,spacer()],height: 32),bar([open,spacer()],height: 40)]),in: sidebar)

        editor.isRichText = false; editor.allowsUndo = true; editor.usesFindBar = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 17)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        editor.delegate = app; editorScroll.hasVerticalScroller = true; editorScroll.autohidesScrollers = true
        editorScroll.documentView = editor
        ruler = LineNumbers(scroll: editorScroll, source: editor)
        ruler?.onClick = { [weak app] number in app?.links.toggle(number) }
        ruler?.toolTip = tr("点击行号，在 PDF 中标红或取消","Click a line number to toggle its PDF ink")
        pdf.onDoubleClick = { [weak app] page,point in app?.links.reverse(page:page,point:point) }
        editorScroll.verticalRulerView = ruler; editorScroll.hasVerticalRuler = true; editorScroll.rulersVisible = true
        let sourceHead = label(tr("源码","SOURCE"), 10, .bold, violet)
        let save = action("", "square.and.arrow.down", app, #selector(App.saveFile))
        save.toolTip = tr("保存  ⌘S","Save  ⌘S"); save.isBordered = false
        let editPane = pane([bar([sourceHead,fileName,spacer(),save],height: 42),line(),editorScroll,line(),bar([caret,spacer(),label("UTF-8",10,.medium,muted)],height: 26)])

        let minus = action("", "minus.magnifyingglass", app, #selector(App.zoomOut))
        let plus = action("", "plus.magnifyingglass", app, #selector(App.zoomIn))
        fitButton.title = ""; fitButton.image = icon("arrow.left.and.right"); fitButton.imagePosition = .imageOnly
        fitButton.bezelStyle = .rounded; fitButton.target = app; fitButton.action = #selector(App.fitPDF)
        fitButton.isEnabled = false
        let export = action("", "square.and.arrow.up", app, #selector(App.exportPDF))
        for (button, tip) in [(minus,tr("缩小","Zoom out")),(plus,tr("放大","Zoom in")),(fitButton,tr("切换到完整页面","Switch to whole page")),(export,tr("导出 PDF","Export PDF"))] {
            button.isBordered = false; button.toolTip = tip
        }
        pdf.displayMode = .singlePageContinuous; pdf.displayDirection = .vertical; pdf.autoScales = true
        pdf.backgroundColor = NSColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1)
        let preview = NSView(); embed(pdf,in: preview); preview.addSubview(pdfHint)
        pdfHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([pdfHint.centerXAnchor.constraint(equalTo: preview.centerXAnchor),pdfHint.centerYAnchor.constraint(equalTo: preview.centerYAnchor)])
        let previewPane = pane([bar([label(tr("PDF 预览","PDF Preview"),13,.semibold),spacer(),minus,plus,fitButton,export],height: 42),line(),preview,line(),bar([pdfPages,spacer(),zoomStatus],height: 26)])
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = app
        for v in [sidebar,editPane,previewPane] { split.addArrangedSubview(v) }

        let engineLabel = label(tr("引擎","Engine"),11,.medium,muted)
        engine.addItems(withTitles: Engine.allCases.map(\.rawValue)); engine.target = app; engine.action = #selector(App.changeEngine)
        compileButton.title = tr("编译","Compile"); compileButton.image = icon("play.fill")
        compileButton.imagePosition = .imageLeading; compileButton.bezelStyle = .rounded; compileButton.bezelColor = violet
        compileButton.target = app; compileButton.action = #selector(App.compile); compileButton.toolTip = tr("编译工程  ⌘↩","Compile project  ⌘↩")
        let logButton = action("", "text.alignleft", app, #selector(App.toggleLog)); logButton.toolTip = tr("编译日志","Build log")
        let top = bar([projectName,mainName,spacer(),status,engineLabel,engine,compileButton,logButton],height: 48)
        let logScroll = NSScrollView(); logScroll.hasVerticalScroller = true; logScroll.documentView = log
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular); log.isEditable = false
        log.isHorizontallyResizable = false; log.autoresizingMask = [.width]; log.textContainerInset = NSSize(width: 10,height: 6)
        logPanel.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let closeLog = action("", "xmark",app,#selector(App.toggleLog)); closeLog.isBordered = false
        embed(pane([line(),bar([label(tr("编译日志","Build log"),11,.semibold),spacer(),closeLog],height: 26),logScroll]),in: logPanel)
        let content = NSView(); window.contentView = content
        embed(pane([top,line(),split,logPanel]),in: content)
        logPanel.isHidden = true
        content.layoutSubtreeIfNeeded()
        split.setPosition(192,ofDividerAt: 0)
        split.setPosition(max(485,content.bounds.width * 0.57),ofDividerAt: 1)
    }
}

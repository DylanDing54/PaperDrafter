import Cocoa
import PDFKit

/// PDFKit owns the nested mouse-handling views. Observe only double clicks within this preview.
final class LinkedPDFView: PDFView {
    var onDoubleClick: ((PDFPage,CGPoint) -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching:.leftMouseDown) { [weak self] event in
            guard let self = self, event.clickCount == 2, event.window === self.window,
                  let content = self.window?.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow,from:nil)),
                  hit === self || hit.isDescendant(of:self), !(hit is NSScroller) else { return event }
            let here = self.convert(event.locationInWindow,from:nil)
            guard let page = self.page(for:here,nearest:false) else { return event }
            self.onDoubleClick?(page,self.convert(here,to:page)); return nil
        }
    }
    deinit { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }
}

/// Repaint the original glyphs in place, then screen red into their ink. White paper stays white.
final class InkMark: PDFAnnotation {
    override func draw(with box: PDFDisplayBox,in context: CGContext) {
        guard let original = page?.pageRef else { return }
        context.saveGState()
        context.clip(to:bounds)
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(bounds)
        context.drawPDFPage(original)
        context.setBlendMode(.screen)
        context.setFillColor(CGColor(red:0.93,green:0.035,blue:0.045,alpha:1)); context.fill(bounds)
        context.restoreGState()
    }
}

/// Match prose across PDF line breaks, discretionary hyphens and typographic ligatures.
/// Keep UTF-16 offsets for both NSTextView and PDFPage selections.
private struct SearchText {
    let key: NSString
    let offsets: [NSRange]
    private static let markup = try! NSRegularExpression(pattern:#"(?<!\\)%[^\n]*|\\(?:cite\w*|label|ref|includegraphics)\*?(?:\[[^\]]*\])*\{[^{}]*\}|\\[a-zA-Z@]+\*?(?:\[[^\]]*\])*"#)
    init(_ source:String, latex:Bool = false) {
        let string = source as NSString
        let omit = latex ? Self.markup.matches(in:source,range:NSRange(location:0,length:string.length)).map(\.range) : []
        var skip = 0, offset = 0, normalized = "", locations = [NSRange]()
        for scalar in source.unicodeScalars {
            let size = scalar.utf16.count
            defer { offset += size }
            while skip < omit.count && NSMaxRange(omit[skip]) <= offset { skip += 1 }
            if skip < omit.count && NSLocationInRange(offset,omit[skip]) { continue }
            for ch in String(scalar).precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(ch) {
                normalized.unicodeScalars.append(ch)
                locations.append(contentsOf:repeatElement(NSRange(location:offset,length:size),count:ch.utf16.count))
            }
        }
        key = normalized as NSString; offsets = locations
    }
    func matches(_ source:SearchText) -> [(keyStart:Int,range:NSRange)] {
        guard source.key.length > 0 else { return [] }
        var start = 0, matches = [(Int,NSRange)]()
        while start < key.length {
            let r = key.range(of:source.key as String,options:.literal,range:NSRange(location:start,length:key.length-start))
            guard r.location != NSNotFound else { break }
            matches.append((r.location,NSUnionRange(offsets[r.location],offsets[NSMaxRange(r)-1])))
            start = NSMaxRange(r)
        }
        return matches
    }
}

final class SourceLinks {
    unowned let app: App
    init(_ app:App) { self.app = app }
    private var map: SyncMap?
    private var buildRevision = -1
    private var pending = [SourceLine:UUID]()
    private var marks = [SourceLine:[InkMark]]()
    private var reverseRequest = UUID()
    private var queued = Set<SourceLine>()
    private var pageText = [Int:SearchText]()
    private let queue = DispatchQueue(label:"local.paperdrafter.synctex",qos:.userInitiated)
    func clear() {
        reverseRequest = UUID(); queued.removeAll(); pending.removeAll()
        for items in marks.values { for mark in items { mark.page?.removeAnnotation(mark) } }
        marks.removeAll(); refreshRuler()
    }
    func reset() { clear(); map = nil; buildRevision = -1; pageText.removeAll() }
    func refreshRuler() {
        let selected = Set(marks.keys).union(pending.keys).union(queued)
        app.ui.ruler?.selected = Set(selected.filter { $0.file == app.draft?.url }.map(\.number))
    }
    func installed(_ newMap: SyncMap?, revision:Int) {
        let restore = Set(marks.keys).union(pending.keys).union(queued)
        clear(); map = newMap; buildRevision = revision; pageText.removeAll()
        if revision != app.revision && !restore.isEmpty {
            queued = restore; refreshRuler(); app.compile(); return
        }
        for line in restore { forward(line) }
    }
    func failedBuild() { queued.removeAll(); refreshRuler() }
    private func notice(_ zh:String,_ en:String) {
        let text = tr(zh,en)
        app.ui.status.stringValue = text
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
            if let self = self, self.app.ui.status.stringValue == text { self.app.update() }
        }
    }
    func toggle(_ number:Int) {
        guard let file = app.draft?.url else { return }
        let line = SourceLine(file:file,number:number)
        if let items = marks.removeValue(forKey:line) {
            for item in items { item.page?.removeAnnotation(item) }
        } else if pending.removeValue(forKey:line) == nil && queued.remove(line) == nil {
            if buildRevision != app.revision || app.pdfURL == nil {
                queued.insert(line); if !app.busy { app.compile() }
            } else { forward(line) }
        }
        refreshRuler()
    }
    private func sourceText(_ line:SourceLine) -> String? {
        if app.draft?.url == line.file, let r = app.ui.ruler?.lines.range(line.number) {
            return (app.ui.editor.string as NSString).substring(with:r)
        }
        guard let str = try? String(contentsOf:line.file,encoding:.utf8) else { return nil }
        let text = str as NSString
        return SourceLines(text).range(line.number).map { text.substring(with:$0) }
    }
    private func text(on page:PDFPage, index:Int) -> SearchText {
        if let value = pageText[index] { return value }
        let value = SearchText(page.string ?? "")
        pageText[index] = value; return value
    }
    private func forward(_ line:SourceLine) {
        guard let map = map, let doc = app.ui.pdf.document else {
            notice("此预览没有 SyncTeX 定位信息","No SyncTeX data for this preview"); return
        }
        guard let str = sourceText(line)?.trimmingCharacters(in:.whitespacesAndNewlines), !str.isEmpty, !str.hasPrefix("%") else {
            notice("此行没有排版内容","This line has no typeset content"); return
        }
        let key = UUID(); pending[line] = key; refreshRuler()
        queue.async {
            let boxes = map.boxes(for:line)
            DispatchQueue.main.async {
                guard self.pending[line] == key, self.app.ui.pdf.document === doc else { return }
                self.pending.removeValue(forKey:line)
                var annotations = [InkMark]()
                let needle = SearchText(str,latex:true)
                var exact = [(PDFPage,[CGRect])]()
                var fallback = [(PDFPage,[CGRect])]()
                for number in Set(boxes.map(\.page)).sorted() {
                    guard let page = doc.page(at:number-1) else { continue }
                    let media = page.bounds(for:.mediaBox)
                    let regions = boxes.filter{$0.page == number}.map{$0.rect(in:media)}.filter{!$0.isNull && $0.width>0 && $0.height>0}
                    guard let first = regions.first else { continue }
                    let textual = self.text(on:page,index:number)
                    var best = [CGRect](), distance = CGFloat.infinity
                    for match in textual.matches(needle) {
                        var r = match.range
                        // Include trailing sentence punctuation where the source and PDF agree.
                        let raw = (page.string ?? "") as NSString
                        if NSMaxRange(r) < raw.length {
                            let next = raw.substring(with:raw.rangeOfComposedCharacterSequence(at:NSMaxRange(r)))
                            if str.hasSuffix(next) { r.length += (next as NSString).length }
                        }
                        let rects = page.selection(for:r)?.selectionsByLine().map{$0.bounds(for:page)} ?? []
                        for rect in rects {
                            for region in regions where region.insetBy(dx:-3,dy:-3).intersects(rect) {
                                let d = abs(region.midY-rect.midY) + abs(region.midX-rect.midX)*0.01
                                if d < distance { best = rects; distance = d }
                            }
                        }
                    }
                    if !best.isEmpty { exact.append((page,best)) }
                    fallback.append((page,str.contains("\\includegraphics") ? [first] : regions))
                }
                for (page,rects) in exact.isEmpty ? fallback : exact {
                    var seen = [CGRect]()
                    for r in rects where !seen.contains(r) {
                        seen.append(r)
                        let mark = InkMark(bounds:r,forType:.square,withProperties:nil)
                        mark.shouldPrint = false; mark.shouldDisplay = true
                        page.addAnnotation(mark); annotations.append(mark)
                    }
                }
                if let first = annotations.first, let page = first.page {
                    self.marks[line] = annotations
                    self.app.ui.pdf.go(to:first.bounds.insetBy(dx:-3,dy:-3),on:page)
                } else { self.notice("此行没有可定位的排版内容","No typeset position for this line") }
                self.refreshRuler()
            }
        }
    }
    func reverse(page:PDFPage, point:CGPoint) {
        guard let doc = app.ui.pdf.document else { return }
        if buildRevision != app.revision {
            if !app.busy { app.compile() }
            notice("预览更新后请再次双击","Double-click again after the preview updates"); return
        }
        guard let map = map else { notice("此预览没有 SyncTeX 定位信息","No SyncTeX data for this preview"); return }
        let index = doc.index(for:page), media = page.bounds(for:.mediaBox)
        let top = CGPoint(x:point.x-media.minX,y:media.maxY-point.y)
        let key = UUID(); reverseRequest = key
        queue.async {
            let result = map.source(page:index+1,point:top)
            DispatchQueue.main.async {
                guard self.reverseRequest == key, self.app.ui.pdf.document === doc, self.app.revision == self.buildRevision else { return }
                guard let (line,column) = result else {
                    self.notice("此处没有工程内的源码位置","No project source at this position"); return
                }
                let editor = self.app.ui.editor
                if self.app.draft?.url != line.file {
                    guard self.app.flush() else { return }
                    self.app.select(line.file)
                }
                guard self.app.draft?.url == line.file, let lines = self.app.ui.ruler?.lines,
                      let r = lines.range(line.number) else { return }
                var cursor = r.location + min(max(column-1,0),max(r.length-1,0))
                let hit = page.characterIndex(at:point)
                if hit >= 0 && hit < page.numberOfCharacters && page.characterBounds(at:hit).insetBy(dx:-1,dy:-1).contains(point) {
                    let printed = self.text(on:page,index:index+1), source = editor.string as NSString
                    let near = (max(1,line.number-5)...min(lines.starts.count,line.number+5)).sorted { abs($0-line.number)<abs($1-line.number) }
                    search: for n in near {
                        guard let range = lines.range(n) else { continue }
                        let fragment = SearchText(source.substring(with:range),latex:true)
                        for match in printed.matches(fragment) where NSLocationInRange(hit,match.range) {
                            var i = 0
                            while i+1 < fragment.offsets.count && printed.offsets[match.keyStart+i+1].location <= hit { i += 1 }
                            cursor = range.location + fragment.offsets[i].location; break search
                        }
                    }
                }
                self.app.window.makeFirstResponder(editor)
                let insertion = NSRange(location:cursor,length:0)
                editor.setSelectedRange(insertion); editor.scrollRangeToVisible(insertion)
                editor.showFindIndicator(for:sourceLineRange(editor.string as NSString, at:cursor))
            }
        }
    }
}
private func sourceLineRange(_ text:NSString,at index:Int) -> NSRange {
    text.lineRange(for:NSRange(location:index,length:0))
}

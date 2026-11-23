import Foundation
import zlib

struct SourceLine: Hashable {
    let file: URL
    let number: Int
}

struct SourceLines {
    private(set) var starts = [0]
    private let length: Int
    init(_ text: NSString) {
        length = text.length
        var index = 0
        while index < length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < length || CharacterSet.newlines.contains(UnicodeScalar(text.character(at: index-1)) ?? " ") {
                starts.append(index)
            }
        }
    }
    func range(_ number: Int) -> NSRange? {
        guard number > 0 && number <= starts.count else { return nil }
        let start = starts[number-1]
        return NSRange(location: start,length: (number < starts.count ? starts[number] : length) - start)
    }
    func number(at index: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high)/2
            if starts[mid] <= index { low = mid+1 } else { high = mid }
        }
        return max(1,low)
    }
}

struct SyncBox {
    let page: Int
    let left: CGFloat, bottom: CGFloat, width: CGFloat, height: CGFloat
    func rect(in media: CGRect) -> CGRect {
        CGRect(x:media.minX + left,y:media.maxY-bottom,width:width,height:height).standardized.intersection(media)
    }
}

struct SyncMap {
    let pdf: URL
    let root: URL
    let main: URL
    let tool: URL
    private let names: [URL:String]

    init?(pdf: URL, root: URL, main: URL, tool: URL) {
        self.pdf = pdf; self.root = canonical(root); self.main = main; self.tool = tool
        let base = pdf.deletingPathExtension()
        guard let map = ["synctex.gz","synctex"].map({base.appendingPathExtension($0)}).first(where:{files.fileExists(atPath:$0.path)}),
              let stream = gzopen(map.path, "rb") else { return nil }
        defer { gzclose(stream) }
        var inputs = [URL:String]()
        var bytes = [CChar](repeating:0,count:8192)
        while gzgets(stream,&bytes,Int32(bytes.count)) != nil {
            guard bytes[0] == 73 else { continue }
            let parts = String(cString:bytes).trimmingCharacters(in:.newlines).split(separator:":",maxSplits:2)
            guard parts.count == 3, parts[0] == "Input" else { continue }
            let name = String(parts[2])
            let path = Self.resolve(name,root:root,main:main)
            if path.path.hasPrefix(self.root.path + "/") { inputs[path] = name }
        }
        names = inputs
    }
    private static func resolve(_ path: String,root: URL,main: URL) -> URL {
        if path.hasPrefix("/") { return canonical(URL(fileURLWithPath:path)) }
        let relative = root.appendingPathComponent(path)
        return canonical(files.fileExists(atPath:relative.path) ? relative : main.deletingLastPathComponent().appendingPathComponent(path))
    }
    private func records(_ args: [String], startingWith key: String) -> [[String:String]] {
        let process = Process(), pipe = Pipe()
        process.executableURL = tool; process.arguments = args; process.currentDirectoryURL = root
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        var rows = [[String:String]]()
        for line in String(decoding:output,as:UTF8.self).split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of:":") else { continue }
            let field = String(line[..<colon])
            if field == key { rows.append([:]) }
            if !rows.isEmpty { rows[rows.count-1][field] = String(line[line.index(after:colon)...]) }
        }
        return rows
    }
    func boxes(for line: SourceLine) -> [SyncBox] {
        guard let name = names[canonical(line.file)] else { return [] }
        return records(["view","-i","\(line.number):0:\(name)","-o",pdf.path],startingWith:"Page").compactMap { r in
            guard let page = Int(r["Page"] ?? ""), page > 0, let x = Double(r["h"] ?? ""),
                  let y = Double(r["v"] ?? ""), let w = Double(r["W"] ?? ""), let h = Double(r["H"] ?? ""),
                  [x,y,w,h].allSatisfy(\.isFinite) else { return nil }
            return SyncBox(page:page,left:x,bottom:y,width:w,height:h)
        }
    }
    func source(page: Int, point: CGPoint) -> (SourceLine,Int)? {
        for r in records(["edit","-o","\(page):\(point.x):\(point.y):\(pdf.path)"],startingWith:"Input") {
            guard let name = r["Input"], let number = Int(r["Line"] ?? ""), number > 0 else { continue }
            let file = Self.resolve(name,root:root,main:main)
            if names[file] != nil && Entry(file,false).editable { return (SourceLine(file:file,number:number),Int(r["Column"] ?? "") ?? -1) }
        }
        return nil
    }
}

import Foundation

let files = FileManager.default
let prefs = UserDefaults.standard
func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
var useEnglish: Bool { prefs.string(forKey: "interfaceLanguage") == "en" }
func tr(_ zh: String, _ en: String) -> String { useEnglish ? en : zh }
struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class Entry {
    let url: URL
    let folder: Bool
    init(_ url: URL, _ folder: Bool) { self.url = canonical(url); self.folder = folder }
    lazy var children: [Entry] = {
        guard folder else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey]
        let urls = (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { child -> Entry? in
            guard let v = try? child.resourceValues(forKeys: keys), v.isSymbolicLink != true,
                  v.isPackage != true, v.isDirectory == true || v.isRegularFile == true else { return nil }
            return Entry(child, v.isDirectory == true)
        }.sorted {
            if $0.folder != $1.folder { return $0.folder }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }()
    var editable: Bool {
        ["tex","bib","sty","cls","txt","md","bst","cfg","def","clo","csv","tikz","ltx","bbl","bbx","cbx","lbx","ist","xml","svg","yaml","json"].contains(url.pathExtension.lowercased())
    }
}

struct Draft {
    let url: URL
    private(set) var original: Data
    let bom: Bool
    let text: String
    init(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        bom = data.starts(with: [0xef, 0xbb, 0xbf])
        guard let source = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else {
            throw Problem(tr("请先将此文件转换为 UTF-8 编码。","Convert this file to UTF-8 to edit it."))
        }
        self.url = url; text = source; original = data
    }
    mutating func save(_ source: String, replace: Bool = false) throws {
        guard replace || (try? Data(contentsOf: url)) == original else {
            throw Problem(tr("文件已在磁盘上更改。","The file has changed on disk."))
        }
        var data = bom ? Data([0xef, 0xbb, 0xbf]) : Data()
        data.append(contentsOf: source.utf8)
        try data.write(to: url, options: .atomic)
        original = data
    }
}

enum Engine: String, CaseIterable {
    case tectonic = "Tectonic", pdf = "pdfLaTeX", xe = "XeLaTeX", lua = "LuaLaTeX"
}
struct BuildResult {
    let log: String
    let pdf: URL?
}
enum Compiler {
    static var path: String {
        let localTeX = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PaperDrafter/TeXLive/2026/bin/universal-darwin").path
        return [localTeX, "/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
    }
    static func executable(_ name: String) -> URL? {
        path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { files.isExecutableFile(atPath: $0.path) }
    }
    static func run(root: URL, main: URL, engine: Engine, output: URL) throws -> BuildResult {
        let tool = engine == .tectonic ? "tectonic" : "latexmk"
        guard let executable = executable(tool) else {
            throw Problem(engine == .tectonic ? tr("找不到 Tectonic。可使用 brew install tectonic 安装。","Tectonic was not found. Install it with brew install tectonic.") :
                tr("此引擎需要 MacTeX 的 latexmk。也可以在引擎菜单选择 Tectonic。","This engine requires latexmk from MacTeX. You can also select Tectonic in the engine menu."))
        }
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        let logURL = output.appendingPathComponent("compiler-output.txt")
        files.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let proc = Process()
        proc.executableURL = executable
        proc.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        if engine != .tectonic { env["LC_ALL"] = "en_US.UTF-8" }
        proc.environment = env
        if engine == .tectonic {
            proc.arguments = ["--untrusted", "--synctex", "--keep-logs", "--outdir", output.path, main.path]
        } else {
            let mode = engine == .pdf ? "-pdf" : (engine == .xe ? "-xelatex" : "-lualatex")
            proc.arguments = ["-norc", mode, "-synctex=1", "-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-no-shell-escape", "-outdir=" + output.path, main.path]
        }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = handle; proc.standardError = handle
        try proc.run()
        proc.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        let size = reader.seekToEndOfFile()
        if size > 256000 { reader.seek(toFileOffset: size - 256000) } else { reader.seek(toFileOffset: 0) }
        let log = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
        let pdf = output.appendingPathComponent(main.deletingPathExtension().lastPathComponent + ".pdf")
        return BuildResult(log: log, pdf: proc.terminationStatus == 0 && files.fileExists(atPath: pdf.path) ? pdf : nil)
    }
}

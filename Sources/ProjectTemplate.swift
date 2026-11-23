import Cocoa

enum ProjectTemplate: CaseIterable {
    case acm, ieee, bilingual, english

    var projectName: String {
        switch self {
        case .acm: return "ACM Paper"
        case .ieee: return "IEEE Paper"
        case .bilingual, .english: return tr("研究笔记","Research notes")
        }
    }

    var engine: Engine {
        switch self {
        case .acm: return .lua
        case .ieee, .english: return .pdf
        case .bilingual: return .xe
        }
    }

    func create(at destination: URL, resources: URL) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".paperdrafter-" + UUID().uuidString)
        defer { try? files.removeItem(at: stage) }
        switch self {
        case .english:
            try files.createDirectory(at: stage, withIntermediateDirectories: false)
            try files.copyItem(at: resources.appendingPathComponent("English.tex"), to: stage.appendingPathComponent("main.tex"))
        case .bilingual, .acm, .ieee:
            let folder = self == .acm ? "Templates/ACM" : (self == .ieee ? "Templates/IEEE" : "Sample")
            try files.copyItem(at: resources.appendingPathComponent(folder), to: stage)
        }
        try files.moveItem(at: stage, to: destination)
    }
}

final class TemplatePicker: NSObject {
    let panel = NSAlert()
    let languages = NSPopUpButton()
    let options = NSStackView()
    var buttons = [NSButton]()
    override init() {
        super.init()
        panel.messageText = tr("选择工程模板","Choose a project template")
        panel.informativeText = tr("下一步选择工程名称和保存位置。","Choose the project name and location in the next step.")
        panel.addButton(withTitle: tr("下一步…","Continue…"))
        panel.addButton(withTitle: tr("取消","Cancel")).keyEquivalent = "\u{1b}"
        options.orientation = .vertical; options.alignment = .leading; options.spacing = 9
        for (index, name) in ["ACM  ·  SIGCONF","IEEE  ·  Conference","Others"].enumerated() {
            let button = NSButton(radioButtonWithTitle: name, target: self, action: #selector(selectOption(_:)))
            button.tag = index; button.state = index == 0 ? .on : .off
            options.addArrangedSubview(button); buttons.append(button)
        }
        languages.addItems(withTitles: [tr("中文与中英混排","Chinese and bilingual"),tr("英文","English")])
        languages.isEnabled = false
        options.addArrangedSubview(stack([label(tr("通用模板","General template"),12,.regular,muted),languages]))
        options.setFrameSize(NSSize(width: 320,height: options.fittingSize.height))
        panel.accessoryView = options
    }
    @objc func selectOption(_ sender: NSButton) {
        for button in buttons { button.state = button === sender ? .on : .off }
        languages.isEnabled = sender.tag == 2
    }
    func choose() -> ProjectTemplate? {
        guard panel.runModal() == .alertFirstButtonReturn else { return nil }
        if buttons[0].state == .on { return .acm }
        if buttons[1].state == .on { return .ieee }
        return languages.indexOfSelectedItem == 0 ? .bilingual : .english
    }
}

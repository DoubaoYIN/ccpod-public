import AppKit

final class LauncherPanel: NSPanel {
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let projectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let terminalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchButton = NSButton(title: "启动", target: nil, action: nil)

    private let providerService = ProviderService()
    private let projectManager = ProjectManager()

    var onLaunch: ((String, String, String) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        self.title = "ccpod · 启动新会话"
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = false
        setupUI()
    }

    func refresh() {
        providerPopup.removeAllItems()
        let providers = providerService.availableProviders()
        for name in providers {
            providerPopup.addItem(withTitle: name)
        }
        let preferred = providerService.preferredLaunchProvider(from: providers)
        if !preferred.isEmpty {
            providerPopup.selectItem(withTitle: preferred)
        }

        projectPopup.removeAllItems()
        for proj in projectManager.recentProjects() {
            projectPopup.addItem(withTitle: proj.path)
        }

        terminalPopup.removeAllItems()
        for adapter in TerminalRegistry.shared.adapters {
            terminalPopup.addItem(withTitle: adapter.name)
        }
        // 默认选中默认终端（iTerm2）
        terminalPopup.selectItem(withTitle: TerminalRegistry.shared.defaultAdapter.name)
    }

    private func setupUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let labels = ["线路:", "项目:", "终端:"]
        let popups = [providerPopup, projectPopup, terminalPopup]
        var y = 150

        for (i, label) in labels.enumerated() {
            let lbl = NSTextField(labelWithString: label)
            lbl.frame = NSRect(x: 16, y: y, width: 50, height: 24)
            lbl.font = .systemFont(ofSize: 13)
            container.addSubview(lbl)

            let popup = popups[i]
            popup.frame = NSRect(x: 70, y: y, width: 230, height: 24)
            popup.font = .systemFont(ofSize: 13)
            container.addSubview(popup)

            y -= 40
        }

        launchButton.frame = NSRect(x: 110, y: 16, width: 100, height: 32)
        launchButton.bezelStyle = .rounded
        launchButton.font = .systemFont(ofSize: 14, weight: .medium)
        launchButton.target = self
        launchButton.action = #selector(doLaunch)
        launchButton.keyEquivalent = "\r"
        container.addSubview(launchButton)

        self.contentView = container
    }

    @objc private func doLaunch() {
        guard let provider = providerPopup.titleOfSelectedItem,
              let project = projectPopup.titleOfSelectedItem,
              let terminal = terminalPopup.titleOfSelectedItem else { return }
        onLaunch?(provider, project, terminal)
        close()
    }
}

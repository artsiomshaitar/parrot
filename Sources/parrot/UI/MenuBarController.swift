import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
///
/// The Model and Hotkey submenus write straight through to `Config`, so a
/// selection here is what parrot uses on every future launch — including when
/// started by the LaunchAgent, which passes no arguments.
@MainActor
final class MenuBarController {
    /// Hotkeys offered in the menu. The full set (f1…f20, keycode:N) stays
    /// CLI-only — a twenty-entry submenu would be noise.
    static let selectableHotkeys: [Hotkey] = [
        .rightCommand, .rightOption, .rightControl, .rightShift, .leftOption, .fn,
    ]

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let modelMenu = NSMenu()
    private let hotkeyMenu = NSMenu()

    private var modelID: String
    private var hotkey: Hotkey
    private var idleTitle: String { "idle · hold \(hotkey.label) to dictate" }

    private let onSelectModel: (String) -> Void
    private let onSelectHotkey: (Hotkey) -> Void
    private let onToggleLaunchAtLogin: () -> Void
    private let launchAtLoginItem: NSMenuItem

    init(
        modelID: String,
        hotkey: Hotkey,
        launchAtLogin: Bool,
        onSelectModel: @escaping (String) -> Void,
        onSelectHotkey: @escaping (Hotkey) -> Void,
        onToggleLaunchAtLogin: @escaping () -> Void
    ) {
        self.modelID = modelID
        self.hotkey = hotkey
        self.onSelectModel = onSelectModel
        self.onSelectHotkey = onSelectHotkey
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.launchAtLoginItem = NSMenuItem(
            title: "Start at login",
            action: #selector(launchAtLoginClicked),
            keyEquivalent: ""
        )
        launchAtLoginItem.state = launchAtLogin ? .on : .off
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        menu.addItem(modelItem)
        menu.setSubmenu(modelMenu, for: modelItem)

        let hotkeyItem = NSMenuItem(title: "Push-to-talk key", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyItem)
        menu.setSubmenu(hotkeyMenu, for: hotkeyItem)

        menu.addItem(.separator())

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit parrot", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu

        buildModelMenu()
        buildHotkeyMenu()
        stateLabel.title = idleTitle
        configureButton()
    }

    // MARK: - Submenus

    private func buildModelMenu() {
        modelMenu.removeAllItems()
        for model in ModelRegistry.shared {
            let item = NSMenuItem(
                title: "\(model.displayName) · \(model.sizeMB) MB",
                action: #selector(modelClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.id
            item.state = (model.id == modelID) ? .on : .off
            modelMenu.addItem(item)
        }
    }

    private func buildHotkeyMenu() {
        hotkeyMenu.removeAllItems()
        for key in Self.selectableHotkeys {
            let item = NSMenuItem(
                title: key.label,
                action: #selector(hotkeyClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = key.label
            item.state = (key == hotkey) ? .on : .off
            hotkeyMenu.addItem(item)
        }
    }

    @objc private func modelClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != modelID else { return }
        onSelectModel(id)
    }

    @objc private func launchAtLoginClicked() {
        onToggleLaunchAtLogin()
    }

    /// Reflects what's actually on disk, so a failed write doesn't leave the
    /// checkmark lying about the state.
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginItem.state = enabled ? .on : .off
    }

    @objc private func hotkeyClicked(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let key = Hotkey(name: label), key != hotkey
        else { return }
        onSelectHotkey(key)
    }

    // MARK: - State

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : idleTitle
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    /// Called once the new model is actually loaded, not when it's picked —
    /// the checkmark should track reality, not intent.
    func setModel(_ id: String) {
        modelID = id
        buildModelMenu()
        stateLabel.title = idleTitle
    }

    func setLoadingModel(_ id: String) {
        stateLabel.title = "loading \(id)…"
    }

    func setHotkey(_ key: Hotkey) {
        hotkey = key
        buildHotkeyMenu()
        stateLabel.title = idleTitle
    }

    // MARK: - Icon

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

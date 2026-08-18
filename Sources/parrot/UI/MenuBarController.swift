import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
@MainActor
final class MenuBarController: NSObject {
    /// Hotkeys offered in the menu. The full set (f1…f20, keycode:N) stays
    static let selectableHotkeys: [Hotkey] = [
        .rightCommand, .rightOption, .rightControl, .rightShift, .leftOption, .fn,
    ]

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let modelMenu = NSMenu()
    private let hotkeyMenu = NSMenu()
    private var modelItems: [NSMenuItem] = []

    private var modelID: String
    private var hotkey: Hotkey
    private var idleTitle: String {
        let prefix = AppIdentity.isDev ? "\(AppIdentity.executableName) · " : ""
        return "\(prefix)idle · hold \(hotkey.label) to dictate"
    }

    /// The model currently being fetched, and how far along. Separate from
    private var downloading: (id: String, fraction: Double)?
    /// Set while a model is downloading or loading; outlives a single dictation
    private var modelStatus: String?
    /// Recording or transcribing — transient, and takes the label while it lasts.
    private var activity: String?

    /// Braille frames rather than an NSProgressIndicator: a real spinner needs
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var spinnerFrame = 0
    private var spinnerTimer: Timer?
    /// The spinner is only visible while the submenu is open, so it only ticks
    private var modelMenuIsOpen = false

    private let onSelectModel: (String) -> Void
    private let onSelectHotkey: (Hotkey) -> Void
    private let onToggleLaunchAtLogin: () -> Void
    private let onEditVocabulary: () -> Void
    private let launchAtLoginItem: NSMenuItem
    private let vocabularyItem: NSMenuItem

    init(
        modelID: String,
        hotkey: Hotkey,
        launchAtLogin: Bool,
        vocabularySummary: String,
        onSelectModel: @escaping (String) -> Void,
        onSelectHotkey: @escaping (Hotkey) -> Void,
        onToggleLaunchAtLogin: @escaping () -> Void,
        onEditVocabulary: @escaping () -> Void
    ) {
        self.modelID = modelID
        self.hotkey = hotkey
        self.onSelectModel = onSelectModel
        self.onSelectHotkey = onSelectHotkey
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onEditVocabulary = onEditVocabulary
        self.vocabularyItem = NSMenuItem(
            title: "Dictionary…",
            action: #selector(editVocabularyClicked),
            keyEquivalent: ""
        )
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

        super.init()

        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        menu.addItem(modelItem)
        menu.setSubmenu(modelMenu, for: modelItem)

        let hotkeyItem = NSMenuItem(title: "Push-to-talk key", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyItem)
        menu.setSubmenu(hotkeyMenu, for: hotkeyItem)

        vocabularyItem.target = self
        menu.addItem(vocabularyItem)

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
        setVocabularySummary(vocabularySummary)
        refreshStateLabel()
        configureButton()
        modelMenu.delegate = self
    }

    // MARK: - Submenus

    private func buildModelMenu() {
        modelMenu.removeAllItems()
        modelItems = ModelRegistry.shared.map { model in
            let item = NSMenuItem(
                title: "",
                action: #selector(modelClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.id
            modelMenu.addItem(item)
            return item
        }
        refreshModelItems()
    }

    /// Titles are rewritten in place rather than rebuilt, so progress can tick
    private func refreshModelItems() {
        for (item, model) in zip(modelItems, ModelRegistry.shared) {
            item.title = "\(model.displayName) · \(detail(for: model))"
            item.state = (model.id == modelID) ? .on : .off
        }
    }

    private func detail(for model: TranscriptionModel) -> String {
        if let downloading, downloading.id == model.id {
            let frame = Self.spinnerFrames[spinnerFrame]
            return "\(frame) downloading \(Int(downloading.fraction * 100))%"
        }
        if ModelStore.isDownloaded(model) { return "\(model.sizeMB) MB" }
        return "\(model.sizeMB) MB · not downloaded"
    }

    /// Runs only while a download is visible in an open submenu.
    private func updateSpinner() {
        let shouldRun = downloading != nil && modelMenuIsOpen
        guard shouldRun else {
            spinnerTimer?.invalidate()
            spinnerTimer = nil
            return
        }
        guard spinnerTimer == nil else { return }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spinnerFrame = (self.spinnerFrame + 1) % Self.spinnerFrames.count
                self.refreshModelItems()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        spinnerTimer = timer
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

    @objc private func editVocabularyClicked() {
        onEditVocabulary()
    }

    /// Reflects what actually parsed, not what the file appears to contain.
    func setVocabularySummary(_ summary: String) {
        vocabularyItem.title = "Dictionary… (\(summary))"
    }

    /// Reflects what's on disk, so a failed write can't leave the state lying.
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

    /// Dictation state wins the label while it's happening, but a model
    private func refreshStateLabel() {
        stateLabel.title = activity ?? modelStatus ?? idleTitle
    }

    func setRecording(_ recording: Bool) {
        activity = recording ? "● recording" : nil
        refreshStateLabel()
    }

    func setTranscribing() {
        activity = "transcribing…"
        refreshStateLabel()
    }

    /// Called once the new model is actually loaded, not when it's picked —
    func setModel(_ id: String) {
        modelID = id
        downloading = nil
        modelStatus = nil
        updateSpinner()
        refreshModelItems()
        refreshStateLabel()
    }

    func setLoadingModel(_ id: String) {
        downloading = nil
        modelStatus = "loading \(ModelRegistry.find(id)?.displayName ?? id)…"
        updateSpinner()
        refreshModelItems()
        refreshStateLabel()
    }

    /// Ignores sub-percent ticks — WhisperKit reports progress far more often
    func setDownloadProgress(_ id: String, _ fraction: Double) {
        let percent = Int(fraction * 100)
        if let downloading, downloading.id == id, Int(downloading.fraction * 100) == percent { return }
        downloading = (id, fraction)
        modelStatus = "downloading \(ModelRegistry.find(id)?.displayName ?? id) · \(percent)%"
        updateSpinner()
        refreshModelItems()
        refreshStateLabel()
    }

    func setHotkey(_ key: Hotkey) {
        hotkey = key
        buildHotkeyMenu()
        refreshStateLabel()
    }

    // MARK: - Icon

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

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
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === modelMenu else { return }
        modelMenuIsOpen = true
        refreshModelItems()
        updateSpinner()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === modelMenu else { return }
        modelMenuIsOpen = false
        updateSpinner()
    }
}

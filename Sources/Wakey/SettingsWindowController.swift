import AppKit
import ApplicationServices

/// The settings window, modelled on System Settings: a translucent source-list sidebar with one
/// item per section, and a detail pane of grouped, rounded cards. Deliberately plain AppKit — no
/// scroll views fighting SwiftUI, and no tab view fighting Auto Layout.
final class SettingsWindowController: NSWindowController {

    private enum Section: Int, CaseIterable, Hashable {
        case general, menuBar, login, receiver, keyboard, remapping, tv, advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .menuBar: return "Menu Bar"
            case .login: return "Login"
            case .receiver: return "Receiver"
            case .keyboard: return "Keyboard"
            case .remapping: return "Remapping"
            case .tv: return "TV"
            case .advanced: return "Advanced"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "How Wakey reacts while your mouse or keyboard charges."
            case .menuBar: return "Choose which devices appear in the menu bar."
            case .login: return "Keep Wakey running after you log in."
            case .receiver: return "The Logitech receiver and the slot Wakey follows."
            case .keyboard: return "Battery, the LED idle timeout, and the top-right macro keys."
            case .remapping: return "Change what a key sends, for every keyboard."
            case .tv: return "Control the LG TV on your network."
            case .advanced: return "Manual controls and diagnostics."
            }
        }

        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .menuBar: return "menubar.rectangle"
            case .login: return "person.crop.circle"
            case .receiver: return "antenna.radiowaves.left.and.right"
            case .keyboard: return "keyboard"
            case .remapping: return "arrow.left.arrow.right"
            case .tv: return "tv"
            case .advanced: return "wrench.and.screwdriver"
            }
        }

        var tint: NSColor {
            switch self {
            case .general: return .systemBlue
            case .menuBar: return .systemPurple
            case .login: return .systemGray
            case .receiver: return .systemGreen
            case .keyboard: return .systemOrange
            case .remapping: return .systemIndigo
            case .tv: return .systemTeal
            case .advanced: return .systemGray
            }
        }

        private var keywords: String {
            switch self {
            case .general: return "automation charging trigger mouse keyboard keep awake sleep dock"
            case .menuBar: return "battery icon menu bar badge visibility"
            case .login: return "startup login item launch agent"
            case .receiver: return "mouse receiver slot rescan sensor logitech usb"
            case .keyboard: return "battery leds timeout keychron macro shortcut teams mute microphone mic f17"
            case .remapping: return "remap key mapping caps lock escape control system all keys"
            case .tv: return "television lg volume brightness power media keys"
            case .advanced: return "blank wake log diagnostics manual"
            }
        }

        func matches(_ query: String) -> Bool {
            title.localizedCaseInsensitiveContains(query)
                || keywords.localizedCaseInsensitiveContains(query)
        }
    }

    private struct RemapDraft {
        let id: UUID
        var source: KeyChoice?
        var target: KeyChoice?

        var mapping: KeyRemap? {
            guard let source, let target else { return nil }
            return KeyRemap(source: source, target: target)
        }
    }

    private enum SidebarRow {
        case header
        case section(Section)
        case spacer

        var section: Section? {
            if case let .section(section) = self { return section }
            return nil
        }
    }

    // MARK: - controls

    private let automateToggle = NSSwitch()
    private let keepAwakeToggle = NSSwitch()
    private let loginToggle = NSSwitch()
    private let badgeToggle = NSSwitch()
    private let showMouseToggle = NSSwitch()
    private let showKeyboardToggle = NSSwitch()
    private let triggerPicker = NSPopUpButton(frame: .zero, pullsDown: false)

    private let receiverLabel = NSTextField(labelWithString: "—")
    private let listeningLabel = NSTextField(labelWithString: "—")
    private let sensorLabel = NSTextField(labelWithString: "—")
    private let keyboardLabel = NSTextField(labelWithString: "no data")
    private let idleTimeoutPicker = NSPopUpButton()
    private let idleTimeoutHint = NSTextField(labelWithString: "")
    private let slotPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginStatusLabel = NSTextField(labelWithString: "—")
    private let accessibilityStatus = NSTextField(labelWithString: "—")

    private let tvToggle = NSSwitch()
    private let tvAddressField = NSTextField(string: "")
    private let tvDetectButton = NSButton(title: "Detect", target: nil, action: nil)
    private let tvConnectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let tvStatusLabel = NSTextField(labelWithString: "—")
    private let tvFollowToggle = NSSwitch()
    private let tvSleepToggle = NSSwitch()
    private let tvKeysToggle = NSSwitch()
    private let tvVolumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let tvVolumeValue = NSTextField(labelWithString: "—")
    private let tvBrightnessSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let tvBrightnessValue = NSTextField(labelWithString: "—")

    private let idleTimeoutFootnote =
        "Wakey firmware: Fn+Y on the keyboard also cycles this over 2.4 GHz."
    private let tvHint =
        "Brightness is the panel's OLED light, not the black-level control. Changes are applied live; "
        + "the TV remote can move them too, so Wakey re-reads them when the menu opens."
    private let lockDelayNote =
        "Displays are switched off with “pmset displaysleepnow”, so both screens go to standby and "
        + "the Mac stays awake to keep listening for the mouse. Your screen-lock delay is 5 minutes: "
        + "shorter charges wake straight back to your desktop, longer ones ask for your password."

    // MARK: - sidebar / detail

    private let searchField = NSSearchField()
    private let sidebarTable = NSTableView()
    private let noResultsLabel = NSTextField(labelWithString: "No Results")
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSubtitle = NSTextField(labelWithString: "")
    private let detailScrollHost = NSView()
    private var detailScrolls: [Section: NSScrollView] = [:]
    private var detailStacks: [Section: NSStackView] = [:]
    private var macroRecorders: [ShortcutRecorderButton] = []
    private let remapToggle = NSSwitch()
    private var remapDrafts: [RemapDraft] = []
    private var remapRowsHost: NSStackView?
    private var sidebarRows: [SidebarRow] = []
    private var selectedSection: Section = .general
    private var isRebuildingSidebar = false

    /// Pushed in by the app delegate.
    var inventory: HIDPPClient.Inventory? {
        didSet { refreshDevice() }
    }
    var liveSummary: String = "—" {
        didSet { sensorLabel.stringValue = liveSummary.isEmpty ? "—" : liveSummary }
    }
    /// Latest pushed reading, which also carries the LED idle timeout over 2.4 GHz (read-only).
    var keyboardReading: KeychronBattery.Reading? { didSet { adoptPushedTimeoutIfIdle() } }

    var keyboardSummary: String = "no data" {
        didSet { keyboardLabel.stringValue = keyboardSummary }
    }

    var onRescan: (() -> Void)?
    var onSelectSlot: ((UInt8?) -> Void)?

    var onTVConnect: ((String) -> Void)?
    var onTVDetect: (() -> Void)?
    var onTVEnabledChanged: (() -> Void)?
    var onTVVolume: ((Int) -> Void)?
    var onTVBacklight: ((Int) -> Void)?
    var onTVMediaKeysChanged: (() -> Void)?
    var onMacroKeysChanged: (() -> Void)?
    var onKeyRemapChanged: (() -> Void)?

    var tvState: TVConnectionState = .off { didSet { refreshTV() } }
    var tvSnapshot: TVSnapshot? { didSet { refreshTV() } }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wakey Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        self.init(window: window)
        buildUI()
        window.center()
        refresh()
    }

    private func buildUI() {
        guard let window else { return }
        configureControls()

        let sidebarController = NSViewController()
        sidebarController.view = makeSidebar()
        let detailController = NSViewController()
        detailController.view = makeDetail()

        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailController))

        window.contentViewController = split
        // Assigning a content view controller adopts its fitting size; restore the window's.
        window.setContentSize(NSSize(width: 900, height: 640))
        split.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(SettingsStyle.sidebarWidth, ofDividerAt: 0)

        rebuildSidebarRows(reselect: false)
        show(.general)
        selectSidebarRow(for: .general)
    }

    // MARK: - sidebar

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0,
                                                       width: SettingsStyle.sidebarWidth,
                                                       height: 640))
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        sidebarTable.headerView = nil
        // `.sourceList` insets every cell by 16 pt on both sides; System Settings' rows run much
        // closer to the sidebar edges, so the row and its selection are drawn full-width here.
        sidebarTable.style = .plain
        sidebarTable.selectionHighlightStyle = .none
        sidebarTable.backgroundColor = .clear
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.rowHeight = 30
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarTable.allowsEmptySelection = false
        sidebarTable.allowsMultipleSelection = false
        sidebarTable.focusRingType = .none
        sidebarTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings.sidebar"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)

        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.documentView = sidebarTable

        noResultsLabel.font = .systemFont(ofSize: 12)
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.isHidden = true
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(searchField)
        sidebar.addSubview(tableScroll)
        sidebar.addSubview(noResultsLabel)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor,
                                             constant: SettingsStyle.sidebarTopInset),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            noResultsLabel.topAnchor.constraint(equalTo: tableScroll.topAnchor, constant: 18),
            noResultsLabel.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
        ])
        return sidebar
    }

    private func rebuildSidebarRows(reselect: Bool) {
        let wanted = selectedSection
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            sidebarRows = [
                .header,
                .section(.general), .section(.menuBar), .section(.login),
                .spacer,
                .section(.receiver), .section(.keyboard), .section(.remapping),
                .spacer,
                .section(.tv),
                .spacer,
                .section(.advanced),
            ]
        } else {
            sidebarRows = Section.allCases
                .filter { $0.matches(query) }
                .map { .section($0) }
        }

        noResultsLabel.isHidden = !(sidebarRows.isEmpty && !query.isEmpty)

        // Reloading can make the table pick a different row by index; ignore those notifications
        // so the visible pane does not jump on its own.
        isRebuildingSidebar = true
        sidebarTable.reloadData()
        isRebuildingSidebar = false

        guard reselect else {
            updateSidebarSelectionAppearance()
            return
        }

        if let row = sidebarRows.firstIndex(where: { $0.section == wanted }) {
            sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateSidebarSelectionAppearance()
        } else if let row = sidebarRows.firstIndex(where: { $0.section != nil }),
                  let section = sidebarRows[row].section {
            selectedSection = section
            show(section)
            sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            sidebarTable.deselectAll(nil)
            updateSidebarSelectionAppearance()
        }
    }

    private func selectSidebarRow(for section: Section) {
        guard let row = sidebarRows.firstIndex(where: { $0.section == section }) else { return }
        sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sidebarTable.scrollRowToVisible(row)
        updateSidebarSelectionAppearance()
    }

    private func updateSidebarSelectionAppearance() {
        let chosen = sidebarTable.selectedRow
        for row in 0..<sidebarRows.count {
            guard let cell = sidebarTable.view(atColumn: 0, row: row,
                                               makeIfNecessary: false) as? SidebarCell else { continue }
            cell.setChosen(row == chosen)
        }
    }

    private func makeSidebarHeaderCell() -> NSView {
        let cell = SidebarCell()
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "Wakey")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "Settings")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(name)
        cell.addSubview(subtitle)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: icon.topAnchor, constant: -2),
            subtitle.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
        return cell
    }

    private func makeSidebarSectionCell(_ section: Section, row: Int) -> NSView {
        let cell = SidebarCell()
        let icon = NSImageView(image: SettingsStyle.sidebarIcon(symbol: section.symbol,
                                                                color: section.tint))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        cell.setChosen(row == sidebarTable.selectedRow)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - detail

    private func makeDetail() -> NSView {
        let detail = SettingsDetailView()

        detailTitle.font = .systemFont(ofSize: 24, weight: .bold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailSubtitle.font = .systemFont(ofSize: 13)
        detailSubtitle.textColor = .secondaryLabelColor
        detailSubtitle.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [detailTitle, detailSubtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(header)

        detailScrollHost.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(detailScrollHost)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.topAnchor,
                                        constant: SettingsStyle.detailTopInset),
            header.leadingAnchor.constraint(equalTo: detail.leadingAnchor,
                                            constant: SettingsStyle.contentInset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: detail.trailingAnchor,
                                             constant: -SettingsStyle.contentInset),
            header.heightAnchor.constraint(equalToConstant: SettingsStyle.detailHeaderHeight),

            detailScrollHost.topAnchor.constraint(
                equalTo: detail.topAnchor,
                constant: SettingsStyle.detailTopInset + SettingsStyle.detailHeaderHeight
                    + SettingsStyle.headerSpacing),
            detailScrollHost.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            detailScrollHost.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            detailScrollHost.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])

        for section in Section.allCases {
            let scroll = makeDetailScroll(for: section)
            detailScrollHost.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: detailScrollHost.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: detailScrollHost.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: detailScrollHost.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: detailScrollHost.bottomAnchor),
            ])
            detailScrolls[section] = scroll
            scroll.isHidden = section != .general
        }
        return detail
    }

    private func makeDetailScroll(for section: Section) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = makeContentStack(for: section)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                           constant: SettingsStyle.contentInset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                            constant: -SettingsStyle.contentInset),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            document.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 40),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        detailStacks[section] = stack
        return scroll
    }

    private func show(_ section: Section) {
        selectedSection = section
        detailTitle.stringValue = section.title
        detailSubtitle.stringValue = section.subtitle

        for (candidate, scroll) in detailScrolls {
            scroll.isHidden = candidate != section
        }
        if let scroll = detailScrolls[section] {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateSidebarSelectionAppearance()
    }

    // MARK: - card construction

    private func makeContentStack(for section: Section) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false

        for group in content(for: section) {
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeGroup(title: String, rows: [NSView], footnote: String? = nil) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        let card = makeCard(rows)
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(header)
        group.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        if let footnote {
            let note = NSTextField(wrappingLabelWithString: footnote)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 520
            group.addArrangedSubview(note)
            group.setCustomSpacing(8, after: card)
            note.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        return group
    }

    private func makeCard(_ rows: [NSView]) -> NSView {
        let card = SettingsCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        for row in rows {
            if !content.arrangedSubviews.isEmpty {
                let separator = SettingsSeparatorView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                content.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return card
    }

    private func makeRow(title: String, subtitle: String? = nil,
                         leading: NSView? = nil, accessory: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.addArrangedSubview(titleLabel)

        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(subtitleLabel)
        }

        // The spacer takes the slack so the switch/button/value column is the same on every row,
        // no matter how long the title is.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        var views: [NSView] = []
        if let leading { views.append(leading) }
        views.append(labels)
        views.append(spacer)
        views.append(accessory)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        row.edgeInsets = SettingsStyle.rowInsets
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func makeMacroGlyph(_ glyph: String) -> NSView {
        let label = NSTextField(labelWithString: glyph)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return label
    }

    private func makeMicrophoneGlyph() -> NSView {
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
        let view = NSImageView(image: image ?? NSImage())
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = .labelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        view.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return view
    }

    private func makeSwitchRow(_ title: String, _ toggle: NSSwitch,
                               subtitle: String? = nil) -> NSView {
        toggle.setAccessibilityLabel(title)
        return makeRow(title: title, subtitle: subtitle, accessory: toggle)
    }

    private func makeValueRow(_ title: String, _ value: NSTextField) -> NSView {
        value.alignment = .right
        value.lineBreakMode = .byTruncatingHead
        return makeRow(title: title, accessory: value)
    }

    private func makeInfoRow(_ label: NSTextField) -> NSView {
        let row = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
        ])
        return row
    }

    private func makeButtonRow(_ title: String, buttons: [NSButton]) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return makeRow(title: title, accessory: stack)
    }

    private func makeSliderRow(_ title: String, slider: NSSlider,
                               value: NSTextField) -> NSView {
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let stack = NSStackView(views: [slider, value])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return makeRow(title: title, accessory: stack)
    }

    private func makeTVAddressAccessory() -> NSView {
        tvAddressField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let stack = NSStackView(views: [tvAddressField, tvDetectButton, tvConnectButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func content(for section: Section) -> [NSView] {
        switch section {
        case .general:
            return [makeGroup(title: "Automation", rows: [
                makeSwitchRow("Automate while the mouse is on its charger", automateToggle,
                              subtitle: "Blanks the displays when the mouse starts charging."),
                makeRow(title: "Blank the displays when this device charges",
                        accessory: triggerPicker),
                makeSwitchRow("Keep this Mac awake while the displays are off", keepAwakeToggle,
                              subtitle: "Stops the Mac from sleeping and dropping the USB receiver."),
            ])]

        case .menuBar:
            return [makeGroup(title: "Menu bar", rows: [
                makeSwitchRow("Show mouse battery", showMouseToggle),
                makeSwitchRow("Show keyboard battery", showKeyboardToggle),
                makeSwitchRow("Green charging badge", badgeToggle,
                              subtitle: "May be hard to see on some wallpapers."),
            ], footnote: "With both devices hidden, Wakey leaves a plain status icon so the menu stays reachable.")]

        case .login:
            return [makeGroup(title: "Login", rows: [
                makeSwitchRow("Start Wakey at login", loginToggle),
                makeValueRow("Login item", loginStatusLabel),
            ], footnote: "Install Wakey in /Applications first; the login item follows the app bundle's location.")]

        case .receiver:
            let receiver = makeGroup(title: "Receiver", rows: [
                makeValueRow("Device", receiverLabel),
                makeValueRow("Listening to", listeningLabel),
                makeRow(title: "Device slot", accessory: slotPicker),
                makeButtonRow("Paired slots", buttons: [rescanButton]),
            ], footnote: "Rescan enumerates all six paired slots. The picker is enabled when more than one slot answers.")
            let sensor = makeGroup(title: "Dock sensor", rows: [makeInfoRow(sensorLabel)])
            return [receiver, sensor]

        case .keyboard:
            let keyboard = makeGroup(title: "Keyboard", rows: [
                makeValueRow("Battery", keyboardLabel),
                makeRow(title: "LEDs off after", accessory: idleTimeoutPicker),
                makeInfoRow(idleTimeoutHint),
            ], footnote: idleTimeoutFootnote)

            let macroSpecs: [(glyph: String?, title: String, detail: String)] = [
                ("○", "Macro 1", "Top-right key · F13"),
                ("△", "Macro 2", "Top-right key · F14"),
                ("□", "Macro 3", "Top-right key · F15"),
                ("✕", "Macro 4", "Top-right key · F16"),
                (nil, "Microphone", "Mic key · F17"),
            ]
            let macroRows = macroSpecs.enumerated().map { offset, spec -> NSView in
                let index = offset + 1
                let recorder = ShortcutRecorderButton()
                recorder.shortcut = Preferences.shared.macroShortcut(for: index)
                recorder.onChange = { [weak self, weak recorder] in
                    guard let recorder else { return }
                    Preferences.shared.setMacroShortcut(recorder.shortcut, for: index)
                    self?.onMacroKeysChanged?()
                }
                macroRecorders.append(recorder)
                let leading = spec.glyph.map(makeMacroGlyph) ?? makeMicrophoneGlyph()
                return makeRow(title: spec.title,
                               subtitle: spec.detail,
                               leading: leading,
                               accessory: recorder)
            }
            let macros = makeGroup(title: "Macro keys", rows: macroRows,
                                   footnote: "Click a shortcut to record one, then press the keys — "
                                   + "Teams mute is ⇧⌘M. Press Delete to clear, Escape to cancel. "
                                   + "The microphone row needs the F17 firmware image. "
                                   + "Requires Accessibility permission.")
            return [keyboard, macros]

        case .remapping:
            return makeRemappingContent()

        case .tv:
            let connection = makeGroup(title: "Connection", rows: [
                makeSwitchRow("Control the TV over the network", tvToggle),
                makeRow(title: "TV address", accessory: makeTVAddressAccessory()),
                makeInfoRow(tvStatusLabel),
            ])
            let behaviour = makeGroup(title: "Behaviour", rows: [
                makeSwitchRow("Turn the TV screen off when Wakey blanks the displays", tvFollowToggle),
                makeSwitchRow("Fully power off when the Mac sleeps", tvSleepToggle,
                              subtitle: "Requires Wake on LAN on the TV."),
                makeSwitchRow("Mac volume and brightness keys control the TV", tvKeysToggle,
                              subtitle: "Requires Accessibility permission."),
            ])
            let audio = makeGroup(title: "Audio & picture", rows: [
                makeSliderRow("Volume", slider: tvVolumeSlider, value: tvVolumeValue),
                makeSliderRow("Brightness", slider: tvBrightnessSlider, value: tvBrightnessValue),
            ], footnote: tvHint)
            let permissions = makeGroup(title: "Permissions", rows: [
                makeValueRow("Accessibility", accessibilityStatus),
                makeButtonRow("System Settings", buttons: [
                    makeButton("Open Accessibility", #selector(openAccessibilitySettings)),
                ]),
            ], footnote: "Needed by TV media keys and the keyboard's macro keys.")
            return [connection, behaviour, audio, permissions]

        case .advanced:
            let manual = makeGroup(title: "Manual control", rows: [
                makeButtonRow("Displays", buttons: [
                    makeButton("Blank now", #selector(blankNow)),
                    makeButton("Wake now", #selector(wakeNow)),
                ]),
            ], footnote: lockDelayNote)
            let diagnostics = makeGroup(title: "Diagnostics", rows: [
                makeButtonRow("Log", buttons: [
                    makeButton("Reveal log in Finder", #selector(revealLog)),
                ]),
                makeInfoRow(statusLabel),
            ])
            return [manual, diagnostics]
        }
    }

    // MARK: - key remapping

    private func makeRemappingContent() -> [NSView] {
        remapDrafts = Preferences.shared.keyRemappings.map {
            RemapDraft(id: UUID(), source: $0.source, target: $0.target)
        }
        remapToggle.state = Preferences.shared.keyRemapEnabled ? .on : .off

        let enable = makeGroup(title: "System remapping", rows: [
            makeSwitchRow("Remap keys for all keyboards", remapToggle,
                          subtitle: "Uses macOS hidutil; active while Wakey is running."),
        ])

        let header = NSTextField(labelWithString: "Mappings")
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        let card = SettingsCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        let host = NSStackView()
        host.orientation = .vertical
        host.alignment = .leading
        host.spacing = 0
        host.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            host.topAnchor.constraint(equalTo: card.topAnchor),
            host.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        remapRowsHost = host
        rebuildRemapRows()

        let note = NSTextField(wrappingLabelWithString:
            "Changes apply to every connected keyboard while Wakey is running, and are cleared when "
            + "Wakey quits. Click a key to record it; click again (or outside) to cancel. "
            + "Media keys are not remappable this way.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520

        let group = NSStackView(views: [header, card, note])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        return [enable, group]
    }

    private func rebuildRemapRows() {
        guard let host = remapRowsHost else { return }
        for view in host.arrangedSubviews {
            host.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if remapDrafts.isEmpty {
            let empty = NSTextField(labelWithString: "No mappings yet.")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false

            let row = NSView()
            row.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
                empty.topAnchor.constraint(equalTo: row.topAnchor, constant: 11),
                empty.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -11),
            ])
            host.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
        } else {
            for (index, draft) in remapDrafts.enumerated() {
                if index > 0 { addRemapSeparator(to: host) }
                let row = makeRemapRow(draft)
                host.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
            }
        }

        addRemapSeparator(to: host)
        let addRow = makeAddRemapRow()
        host.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
    }

    private func addRemapSeparator(to host: NSStackView) {
        let separator = SettingsSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        host.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    private func makeRemapRow(_ draft: RemapDraft) -> NSView {
        let source = KeyRecorderButton()
        source.choice = draft.source
        source.setAccessibilityLabel("Source key")
        source.onChange = { [weak self] choice in
            self?.updateRemapSource(draft.id, choice)
        }

        let target = KeyRecorderButton()
        target.choice = draft.target
        target.setAccessibilityLabel("Target key")
        target.onChange = { [weak self] choice in
            self?.updateRemapTarget(draft.id, choice)
        }

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 13)
        arrow.textColor = .secondaryLabelColor

        let remove = NSButton()
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove mapping")
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove mapping"
        remove.target = self
        remove.action = #selector(removeRemapRow(_:))
        remove.identifier = NSUserInterfaceItemIdentifier(draft.id.uuidString)
        remove.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [source, arrow, target, spacer, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.edgeInsets = SettingsStyle.rowInsets
        source.setContentHuggingPriority(.required, for: .horizontal)
        target.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeAddRemapRow() -> NSView {
        let button = makeButton("Add Mapping", #selector(addRemapMapping))
        let row = NSStackView(views: [button])
        row.orientation = .horizontal
        row.edgeInsets = SettingsStyle.rowInsets
        return row
    }

    @objc private func addRemapMapping() {
        remapDrafts.append(RemapDraft(id: UUID()))
        rebuildRemapRows()
    }

    @objc private func removeRemapRow(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw),
              let index = remapDrafts.firstIndex(where: { $0.id == id }) else { return }
        remapDrafts.remove(at: index)
        rebuildRemapRows()
        saveRemapDrafts()
    }

    private func updateRemapSource(_ id: UUID, _ choice: KeyChoice) {
        guard let index = remapDrafts.firstIndex(where: { $0.id == id }) else { return }
        remapDrafts[index].source = choice
        saveRemapDrafts()
    }

    private func updateRemapTarget(_ id: UUID, _ choice: KeyChoice) {
        guard let index = remapDrafts.firstIndex(where: { $0.id == id }) else { return }
        remapDrafts[index].target = choice
        saveRemapDrafts()
    }

    private func saveRemapDrafts() {
        Preferences.shared.setKeyRemappings(remapDrafts.compactMap(\.mapping))
        onKeyRemapChanged?()
    }

    @objc private func remapEnabledChanged() {
        Preferences.shared.keyRemapEnabled = remapToggle.state == .on
        onKeyRemapChanged?()
    }

    // MARK: - control setup

    private func configureControls() {
        automateToggle.target = self
        automateToggle.action = #selector(automateChanged)
        keepAwakeToggle.target = self
        keepAwakeToggle.action = #selector(keepAwakeChanged)
        loginToggle.target = self
        loginToggle.action = #selector(loginChanged)
        badgeToggle.target = self
        badgeToggle.action = #selector(badgeChanged)
        showMouseToggle.target = self
        showMouseToggle.action = #selector(visibilityChanged)
        showKeyboardToggle.target = self
        showKeyboardToggle.action = #selector(visibilityChanged)

        remapToggle.target = self
        remapToggle.action = #selector(remapEnabledChanged)

        triggerPicker.target = self
        triggerPicker.action = #selector(triggerChanged)
        triggerPicker.addItems(withTitles: ["The mouse (on its dock)", "The keyboard (charging)"])
        triggerPicker.widthAnchor.constraint(equalToConstant: 210).isActive = true

        for label in [receiverLabel, listeningLabel, keyboardLabel, loginStatusLabel,
                      accessibilityStatus] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.lineBreakMode = .byTruncatingHead
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        keyboardLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        sensorLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sensorLabel.textColor = .secondaryLabelColor
        sensorLabel.lineBreakMode = .byTruncatingMiddle

        slotPicker.target = self
        slotPicker.action = #selector(slotChanged)
        slotPicker.widthAnchor.constraint(equalToConstant: 190).isActive = true

        rescanButton.target = self
        rescanButton.action = #selector(rescanNow)
        rescanButton.bezelStyle = .rounded

        idleTimeoutPicker.addItems(withTitles: ["Never", "15 s", "30 s", "60 s", "90 s"])
        idleTimeoutPicker.target = self
        idleTimeoutPicker.action = #selector(idleTimeoutChanged)
        idleTimeoutPicker.widthAnchor.constraint(equalToConstant: 100).isActive = true
        idleTimeoutHint.font = .systemFont(ofSize: 11)
        idleTimeoutHint.textColor = .secondaryLabelColor
        idleTimeoutHint.lineBreakMode = .byTruncatingTail

        tvToggle.target = self
        tvToggle.action = #selector(tvToggleChanged)
        tvFollowToggle.target = self
        tvFollowToggle.action = #selector(tvFollowChanged)
        tvSleepToggle.target = self
        tvSleepToggle.action = #selector(tvSleepChanged)
        tvKeysToggle.target = self
        tvKeysToggle.action = #selector(tvKeysChanged)

        tvAddressField.placeholderString = "10.210.15.90"
        tvAddressField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tvAddressField.stringValue = Preferences.shared.tvHost

        tvDetectButton.target = self
        tvDetectButton.action = #selector(tvDetectNow)
        tvDetectButton.bezelStyle = .rounded
        tvConnectButton.target = self
        tvConnectButton.action = #selector(tvConnectNow)
        tvConnectButton.bezelStyle = .rounded

        tvStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tvStatusLabel.textColor = .secondaryLabelColor
        tvStatusLabel.lineBreakMode = .byTruncatingMiddle

        tvVolumeSlider.target = self
        tvVolumeSlider.action = #selector(tvVolumeChanged)
        tvVolumeSlider.isContinuous = false
        tvVolumeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tvVolumeValue.textColor = .secondaryLabelColor
        tvVolumeValue.alignment = .right

        tvBrightnessSlider.target = self
        tvBrightnessSlider.action = #selector(tvBrightnessChanged)
        tvBrightnessSlider.isContinuous = false
        tvBrightnessValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tvBrightnessValue.textColor = .secondaryLabelColor
        tvBrightnessValue.alignment = .right

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    // MARK: - refresh

    func refresh() {
        let prefs = Preferences.shared
        automateToggle.state = prefs.automate ? .on : .off
        keepAwakeToggle.state = prefs.keepAwake ? .on : .off
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        badgeToggle.state = prefs.coloredBadge ? .on : .off
        showMouseToggle.state = prefs.showMouse ? .on : .off
        showKeyboardToggle.state = prefs.showKeyboard ? .on : .off
        triggerPicker.selectItem(at: prefs.trigger == .keyboard ? 1 : 0)
        loginStatusLabel.stringValue = LoginItem.statusDescription
        statusLabel.stringValue = "log: \(Log.shared.logPath)"
        tvToggle.state = prefs.tvControl ? .on : .off
        tvFollowToggle.state = prefs.tvFollowDisplays ? .on : .off
        tvSleepToggle.state = prefs.tvPowerOffOnSleep ? .on : .off
        tvKeysToggle.state = prefs.tvMediaKeys ? .on : .off
        accessibilityStatus.stringValue = AXIsProcessTrusted() ? "Granted" : "Not granted"
        remapToggle.state = prefs.keyRemapEnabled ? .on : .off
        if tvAddressField.currentEditor() == nil {
            tvAddressField.stringValue = prefs.tvHost
        }
        refreshTV()
        refreshDevice()
        refreshIdleTimeout()
        refreshMacroRecorders()
    }

    private func refreshMacroRecorders() {
        for (offset, recorder) in macroRecorders.enumerated() where !recorder.isRecording {
            recorder.shortcut = Preferences.shared.macroShortcut(for: offset + 1)
        }
    }

    /// Pushed by the app delegate after a successful SSDP detect, or by the address field.
    func setTVHost(_ host: String) {
        tvAddressField.stringValue = host
        refreshTV()
    }

    private func refreshTV() {
        let ready = tvState == .ready
        tvVolumeSlider.isEnabled = ready
        tvBrightnessSlider.isEnabled = ready

        var status: String
        switch tvState {
        case .ready:
            status = "Connected"
            if let model = tvSnapshot?.model { status += " to \(model)" }
            if let app = tvSnapshot?.currentApp {
                status += " · input \(app.replacingOccurrences(of: "com.webos.app.", with: ""))"
            }
            if tvSnapshot?.isScreenOff == true { status += " · screen off" }
        case .pairing:
            status = "Waiting for approval on the TV screen."
        case .connecting:
            status = "Connecting…"
        case .unreachable:
            status = "Not reachable. Check the address and the TV's Wake on LAN setting."
        case .off:
            status = Preferences.shared.tvControl
                ? "TV control is on. Connect to start."
                : "TV control is off."
        }
        tvStatusLabel.stringValue = status

        if let snapshot = tvSnapshot {
            if let volume = snapshot.volume {
                tvVolumeSlider.doubleValue = Double(volume)
                tvVolumeValue.stringValue = "\(volume)%"
            }
            if let backlight = snapshot.backlight {
                tvBrightnessSlider.doubleValue = Double(backlight)
                tvBrightnessValue.stringValue = "\(backlight)%"
            }
        } else {
            tvVolumeValue.stringValue = "—"
            tvBrightnessValue.stringValue = "—"
        }
    }

    /// Values offered in the popup, in the same order as their titles.
    private let idleTimeoutValues = [0, 15, 30, 60, 90]

    /// Reads the timeout from the keyboard. Only possible with the cable in: the dongle carries
    /// keyboard → host only, so a reply is the one thing a wired keyboard can give us.
    private func refreshIdleTimeout() {
        idleTimeoutHint.stringValue = "reading…"
        idleTimeoutPicker.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = KeychronConfig.readIdleTimeout()
            DispatchQueue.main.async { self.apply(result, wrote: false) }
        }
    }

    @objc private func idleTimeoutChanged() {
        let index = idleTimeoutPicker.indexOfSelectedItem
        guard index >= 0, index < idleTimeoutValues.count else { return }
        let seconds = idleTimeoutValues[index]
        idleTimeoutHint.stringValue = "writing…"
        idleTimeoutPicker.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = KeychronConfig.writeIdleTimeout(seconds)
            DispatchQueue.main.async { self.apply(result, wrote: true) }
        }
    }

    private func apply(_ result: KeychronConfigResult, wrote: Bool) {
        switch result {
        case .ok(let seconds):
            idleTimeoutPicker.isEnabled = true
            if let index = idleTimeoutValues.firstIndex(of: seconds) {
                idleTimeoutPicker.selectItem(at: index)
            }
            idleTimeoutHint.stringValue = wrote
                ? "saved to the keyboard"
                : "stored on the keyboard"
            log("keyboard: idle LED timeout \(wrote ? "set" : "read") to \(seconds) s over USB")

        case .noDevice:
            idleTimeoutPicker.isEnabled = false
            // The value still arrives with the battery push: no request needed, nothing sent.
            if let seconds = keyboardReading?.idleTimeoutSeconds,
               let index = idleTimeoutValues.firstIndex(of: seconds) {
                idleTimeoutPicker.selectItem(at: index)
                idleTimeoutHint.stringValue = "read over 2.4 GHz — connect USB to change"
            } else {
                idleTimeoutHint.stringValue = "connect USB to change"
            }
            log("keyboard: idle LED timeout not writable here (dongle cannot carry host → keyboard)")

        case .noReply:
            idleTimeoutPicker.isEnabled = false
            idleTimeoutHint.stringValue = "keyboard did not answer (0xA5)"
            log("keyboard: idle LED timeout not available over this link")
        }
    }

    /// Called when the app reads the value over USB, so an open panel reflects it immediately.
    func adoptIdleTimeout(_ seconds: Int) {
        guard let index = idleTimeoutValues.firstIndex(of: seconds) else { return }
        idleTimeoutPicker.selectItem(at: index)
        idleTimeoutPicker.isEnabled = true
        idleTimeoutHint.stringValue = "stored on the keyboard"
    }

    /// Keeps the read-only value fresh while Settings is open, without re-querying the keyboard.
    private func adoptPushedTimeoutIfIdle() {
        guard idleTimeoutHint.stringValue.contains("2.4 GHz"),
              let seconds = keyboardReading?.idleTimeoutSeconds,
              let index = idleTimeoutValues.firstIndex(of: seconds) else { return }
        idleTimeoutPicker.selectItem(at: index)
    }

    private func refreshDevice() {
        guard let inventory else {
            receiverLabel.stringValue = "Not found"
            listeningLabel.stringValue = "—"
            slotPicker.removeAllItems()
            slotPicker.addItem(withTitle: "Automatic")
            slotPicker.isEnabled = false
            return
        }

        receiverLabel.stringValue = inventory.receiverLabel

        if let active = inventory.active {
            let others = inventory.responders.count - 1
            let suffix = others > 0
                ? " (\(others) other slot\(others == 1 ? "" : "s") also answering)"
                : " (only slot answering)"
            listeningLabel.stringValue = String(
                format: "slot 0x%02x, battery feature 0x%02x%@",
                active.slot, active.batteryFeature, suffix)
        } else {
            listeningLabel.stringValue = "Nothing — the mouse is not answering"
        }

        slotPicker.removeAllItems()
        slotPicker.addItem(withTitle: "Automatic")
        for responder in inventory.responders {
            slotPicker.addItem(withTitle: String(format: "Slot 0x%02x (feature 0x%02x)",
                                                 responder.slot, responder.batteryFeature))
        }

        // Only offer a real choice when there is one to make.
        let multi = inventory.responders.count > 1
        slotPicker.isEnabled = multi
        slotPicker.toolTip = multi ? nil : "Only one slot is answering."
        let preferred = Preferences.shared.deviceSlot
        if multi, preferred > 0,
           let index = inventory.responders.firstIndex(where: { $0.slot == UInt8(preferred) }) {
            slotPicker.selectItem(at: index + 1)
        } else {
            slotPicker.selectItem(at: 0)
        }
    }

    /// Used by the TV menu, which should land directly on the TV pane.
    func selectTVSection() {
        searchField.stringValue = ""
        rebuildSidebarRows(reselect: false)
        show(.tv)
        selectSidebarRow(for: .tv)
    }

    /// Used by `--selftest` to catch a pane whose content overflows the detail column.
    func layoutReport() -> String {
        guard let window else { return "no window" }
        let split = window.contentViewController as? NSSplitViewController
        split?.view.layoutSubtreeIfNeeded()
        let sidebarWidth = split?.splitViewItems.first?.viewController.view.frame.width ?? 0
        let detailWidth = max(0, window.frame.width - sidebarWidth)

        var parts: [String] = []
        var allFit = true
        for section in Section.allCases {
            guard let stack = detailStacks[section] else { continue }
            stack.layoutSubtreeIfNeeded()
            let fitting = stack.fittingSize
            let available = detailWidth - 2 * SettingsStyle.contentInset
            let fits = fitting.width <= available + 1
            allFit = allFit && fits
            parts.append(String(format: "%@ %.0fx%.0f %@", section.title,
                                fitting.width, fitting.height, fits ? "fits" : "OVERFLOWS"))
        }
        return String(format: "window %.0fx%.0f, sidebar %.0f, detail %.0f — %@ — %@",
                      window.frame.width, window.frame.height, sidebarWidth, detailWidth,
                      parts.joined(separator: " · "), allFit ? "fits" : "OVERFLOWS")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - actions

    @objc private func automateChanged() {
        Preferences.shared.automate = (automateToggle.state == .on)
        log("settings: automation = \(Preferences.shared.automate)")
        refresh()
    }

    @objc private func badgeChanged() {
        Preferences.shared.coloredBadge = (badgeToggle.state == .on)
        log("settings: coloredBadge = \(Preferences.shared.coloredBadge)")
        refresh()
    }

    @objc private func visibilityChanged() {
        Preferences.shared.showMouse = (showMouseToggle.state == .on)
        Preferences.shared.showKeyboard = (showKeyboardToggle.state == .on)
        log("settings: showMouse = \(Preferences.shared.showMouse), showKeyboard = \(Preferences.shared.showKeyboard)")
        refresh()
    }

    @objc private func triggerChanged() {
        Preferences.shared.trigger = triggerPicker.indexOfSelectedItem == 1 ? .keyboard : .mouse
        log("settings: trigger = \(Preferences.shared.trigger == .keyboard ? "keyboard" : "mouse")")
        refresh()
    }

    @objc private func keepAwakeChanged() {
        Preferences.shared.keepAwake = (keepAwakeToggle.state == .on)
        log("settings: keepAwake = \(Preferences.shared.keepAwake)")
    }

    @objc private func loginChanged() {
        let wants = (loginToggle.state == .on)
        if let failure = LoginItem.setEnabled(wants) {
            loginToggle.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = failure
            alert.alertStyle = .warning
            alert.runModal()
        }
        refresh()
    }

    @objc private func slotChanged() {
        let index = slotPicker.indexOfSelectedItem
        if index <= 0 {
            Preferences.shared.deviceSlot = 0
            onSelectSlot?(nil)
        } else {
            let responder = inventory?.responders[index - 1]
            Preferences.shared.deviceSlot = Int(responder?.slot ?? 0)
            onSelectSlot?(responder?.slot)
        }
        log("settings: device slot preference = \(Preferences.shared.deviceSlot)")
    }

    @objc private func tvToggleChanged() {
        Preferences.shared.tvControl = tvToggle.state == .on
        log("settings: TV control = \(Preferences.shared.tvControl)")
        onTVEnabledChanged?()
        refresh()
    }

    @objc private func tvFollowChanged() {
        Preferences.shared.tvFollowDisplays = tvFollowToggle.state == .on
        log("settings: TV follows displays = \(Preferences.shared.tvFollowDisplays)")
    }

    @objc private func tvSleepChanged() {
        Preferences.shared.tvPowerOffOnSleep = tvSleepToggle.state == .on
        log("settings: TV off on sleep = \(Preferences.shared.tvPowerOffOnSleep)")
    }

    @objc private func tvKeysChanged() {
        Preferences.shared.tvMediaKeys = tvKeysToggle.state == .on
        log("settings: TV media keys = \(Preferences.shared.tvMediaKeys)")
        onTVMediaKeysChanged?()
    }

    @objc private func tvDetectNow() {
        log("settings: TV detect requested")
        onTVDetect?()
    }

    @objc private func tvConnectNow() {
        onTVConnect?(tvAddressField.stringValue)
    }

    @objc private func tvVolumeChanged() {
        let value = Int(tvVolumeSlider.doubleValue.rounded())
        tvVolumeValue.stringValue = "\(value)%"
        onTVVolume?(value)
    }

    @objc private func tvBrightnessChanged() {
        let value = Int(tvBrightnessSlider.doubleValue.rounded())
        tvBrightnessValue.stringValue = "\(value)%"
        onTVBacklight?(value)
    }

    @objc private func rescanNow() {
        log("settings: rescan requested")
        onRescan?()
    }

    @objc private func blankNow() {
        NotificationCenter.default.post(name: .wakeyBlankNow, object: nil)
    }

    @objc private func wakeNow() {
        NotificationCenter.default.post(name: .wakeyWakeNow, object: nil)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.shared.logPath)])
    }
}

// MARK: - sidebar table

private final class SidebarCell: NSTableCellView {
    /// Drawn by the cell rather than by NSTableView so the selection is rounded and inset, and so
    /// it survives an offscreen render in `--selftest`.
    var isChosen = false {
        didSet {
            applyTextColor()
            needsDisplay = true
        }
    }

    func setChosen(_ chosen: Bool) {
        isChosen = chosen
        applyTextColor()
    }

    /// NSTableView's source-list style also nudges the cell's text colour around selection; keep
    /// it in step with our own highlight whenever it does.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    override func layout() {
        super.layout()
        applyTextColor()
    }

    private func applyTextColor() {
        textField?.textColor = isChosen
            ? NSColor.alternateSelectedControlTextColor
            : NSColor.labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            NSColor.controlAccentColor.setFill()
            let selection = NSRect(x: 4, y: 2, width: max(0, bounds.width - 14),
                                   height: max(0, bounds.height - 4))
            NSBezierPath(roundedRect: selection, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        sidebarRows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch sidebarRows[row] {
        case .header: return 54
        case .spacer: return 10
        case .section: return 30
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        sidebarRows[row].section != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < sidebarRows.count else { return nil }
        switch sidebarRows[row] {
        case .header:
            return makeSidebarHeaderCell()
        case .spacer:
            return NSView()
        case .section(let section):
            return makeSidebarSectionCell(section, row: row)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRebuildingSidebar else { return }
        guard let table = notification.object as? NSTableView, table === sidebarTable else { return }
        let row = sidebarTable.selectedRow
        guard row >= 0, row < sidebarRows.count,
              let section = sidebarRows[row].section else { return }
        show(section)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        rebuildSidebarRows(reselect: true)
    }
}

extension Notification.Name {
    static let wakeyBlankNow = Notification.Name("nl.sortedbits.wakey.blankNow")
    static let wakeyWakeNow = Notification.Name("nl.sortedbits.wakey.wakeNow")
}

import AppKit

/// “Find a TV” panel: scans SSDP, lists every LG webOS TV that answered, and lets the user pick
/// one or fall back to a typed address. A normal window that activates the accessory app — the old
/// NSAlert could open behind whatever was frontmost.
final class TVScannerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    var onScan: (() -> Void)?
    var onConnect: ((String) -> Void)?

    private var devices: [TVController.DiscoveredTV] = []
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let scanButton = NSButton(title: "Scan again", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let addressField = NSTextField(string: "")
    private let useAddressButton = NSButton(title: "Use address", target: nil, action: nil)
    private let stack = NSStackView()
    private let cellIdentifier = NSUserInterfaceItemIdentifier("TVDeviceCell")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Find a TV"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        // A picker that vanishes behind the browser is useless; keep it above normal windows
        // until the user connects or closes it.
        window.level = .floating
        window.center()
        self.init(window: window)
        buildUI()
        refreshCurrentAddressHint()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Find your TV")
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Wakey looks for LG webOS TVs on the local network. The TV has to be on and reachable.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 480

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY

        table.headerView = nil
        table.rowHeight = 46
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 196).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 480).isActive = true

        scanButton.target = self
        scanButton.action = #selector(scanAgain)
        scanButton.bezelStyle = .rounded

        connectButton.target = self
        connectButton.action = #selector(connectSelected)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.isEnabled = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [scanButton, NSView(), connectButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let manualLabel = NSTextField(labelWithString: "Or enter the TV's address:")
        manualLabel.font = NSFont.systemFont(ofSize: 12)

        addressField.placeholderString = "10.210.13.16"
        addressField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        addressField.target = self
        addressField.action = #selector(useAddress)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        useAddressButton.target = self
        useAddressButton.action = #selector(useAddress)
        useAddressButton.bezelStyle = .rounded

        let manualRow = NSStackView(views: [addressField, useAddressButton])
        manualRow.orientation = .horizontal
        manualRow.spacing = 8
        manualRow.alignment = .centerY

        let footnote = NSTextField(wrappingLabelWithString:
            "If the TV is in standby, Wake on LAN must be enabled on it before Wakey can wake it. "
            + "A wired connection is more reliable for that than Wi-Fi.")
        footnote.font = NSFont.systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        footnote.preferredMaxLayoutWidth = 480

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(14, after: subtitle)
        stack.addArrangedSubview(statusRow)
        stack.addArrangedSubview(scrollView)
        stack.setCustomSpacing(12, after: scrollView)
        stack.addArrangedSubview(buttonRow)
        stack.setCustomSpacing(16, after: buttonRow)
        stack.addArrangedSubview(manualLabel)
        stack.addArrangedSubview(manualRow)
        stack.setCustomSpacing(12, after: manualRow)
        stack.addArrangedSubview(footnote)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func refreshCurrentAddressHint() {
        let current = Preferences.shared.tvHost
        addressField.placeholderString = current.isEmpty ? "10.210.13.16" : current
    }

    // MARK: - presenting

    func startScan() {
        refreshCurrentAddressHint()
        present()
        beginScanning()
        onScan?()
    }

    private func present() {
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func beginScanning() {
        devices = []
        table.reloadData()
        table.deselectAll(nil)
        connectButton.isEnabled = false
        scanButton.isEnabled = false
        statusLabel.stringValue = "Scanning the local network…"
        spinner.startAnimation(nil)
    }

    func showResults(_ devices: [TVController.DiscoveredTV]) {
        spinner.stopAnimation(nil)
        scanButton.isEnabled = true
        self.devices = devices
        table.reloadData()

        guard !devices.isEmpty else {
            statusLabel.stringValue = "No LG TVs answered. Check the TV is on, then scan again or type its address."
            connectButton.isEnabled = false
            return
        }

        statusLabel.stringValue = devices.count == 1
            ? "1 TV found — select it and click Connect."
            : "\(devices.count) TVs found — choose one."
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        connectButton.isEnabled = true
    }

    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        scanButton.isEnabled = true
        statusLabel.stringValue = message
        connectButton.isEnabled = false
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = devices[row]
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? TVDeviceCellView)
            ?? TVDeviceCellView()
        cell.identifier = cellIdentifier
        cell.nameLabel.stringValue = device.name ?? device.model ?? "LG TV"
        var detail = device.host
        if let model = device.model, model != cell.nameLabel.stringValue {
            detail += " · \(model)"
        }
        cell.detailLabel.stringValue = detail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        connectButton.isEnabled = table.selectedRow >= 0 && !devices.isEmpty
    }

    // MARK: - actions

    @objc private func scanAgain() {
        beginScanning()
        onScan?()
    }

    @objc private func connectSelected() {
        let row = table.selectedRow
        guard row >= 0, row < devices.count else { return }
        onConnect?(devices[row].host)
        close()
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < devices.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onConnect?(devices[row].host)
        close()
    }

    @objc private func useAddress() {
        let host = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            NSSound.beep()
            return
        }
        onConnect?(host)
        close()
    }

    @objc private func cancel() {
        close()
    }

    /// Used by `--selftest`.
    func layoutReport() -> String {
        guard let content = window?.contentView else { return "no content view" }
        content.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let available = content.bounds.size
        let fits = fitting.height <= available.height + 1 && fitting.width <= available.width + 1
        return String(format: "stack %.0fx%.0f in %.0fx%.0f — %@",
                      fitting.width, fitting.height, available.width, available.height,
                      fits ? "fits" : "OVERFLOWS")
    }
}

/// Two-line row: friendly name on top, address/model underneath. Colours follow the table's
/// selection so the text stays readable on the blue highlight.
private final class TVDeviceCellView: NSTableCellView {
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        for label in [nameLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            nameLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            detailLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}

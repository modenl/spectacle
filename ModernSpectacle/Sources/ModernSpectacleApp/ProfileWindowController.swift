import AppKit
import ModernSpectacleCore
import ModernSpectacleServices

/// Shows what Smart Arrange remembers about the user and why the last layout came out the way it did.
/// Notes and per-app styles are editable; the next arrangement uses the edited memory.
@MainActor
final class ProfileWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let model: AppModel
    private let lastLayout = NSTextField(wrappingLabelWithString: "")
    private let notesView = NSTextView()
    private let notesSaved = NSTextField(labelWithString: "")
    private let stylesTable = NSTableView()
    private let correctionsTable = NSTableView()
    private let arrangementsTable = NSTableView()

    private var styles: [(bundleID: String, style: ArrangementStyle)] = []
    private var corrections: [LayoutCorrection] = []
    private var arrangements: [ArrangementRecord] = []
    private var appNames: [String: String] = [:]

    private static let styleOptions: [ArrangementStyle] = [.tiled, .cascaded]

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Layout Profile"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        model.arranger.onHistoryChange = { [weak self] _ in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data

    private func reload() {
        let history = model.arranger.history
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = app.localizedName { appNames[id] = name }
        }
        styles = history.appStyles.map { ($0.key, $0.value) }.sorted { $0.bundleID < $1.bundleID }
        corrections = history.corrections.reversed()
        arrangements = history.arrangements.reversed()

        if notesView.string != history.notes, window?.firstResponder !== notesView {
            notesView.string = history.notes
        }

        if let last = arrangements.first {
            let request = model.arranger.lastRequest
            let seen = request.map { req -> String in
                let focused = req.windows.first { $0.id == req.focusedWindowID }.map { "\($0.app) – \($0.title)" } ?? "none"
                let timeline = req.focusTimeline.prefix(6).map { "\($0.app) \($0.dwellSeconds)s" }.joined(separator: " ← ")
                return "Saw \(req.windows.count) windows on \(req.displays.count) display(s). Focus: \(focused). Recent: \(timeline)"
            } ?? ""
            let took = last.durationMs.map { " · \($0) ms" } ?? ""
            lastLayout.stringValue = "\(Self.dateFormatter.string(from: last.date)) · \(last.planner) · moved \(last.windowCount)\(took)\n\(last.summary)\n\(seen)"
        } else {
            lastLayout.stringValue = "No arrangement yet. Press ⌃⌥⌘A."
        }

        stylesTable.reloadData()
        correctionsTable.reloadData()
        arrangementsTable.reloadData()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func name(for bundleID: String) -> String {
        appNames[bundleID] ?? bundleID
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        stack.addArrangedSubview(header("Why the current layout"))
        lastLayout.preferredMaxLayoutWidth = 600
        lastLayout.textColor = .secondaryLabelColor
        stack.addArrangedSubview(lastLayout)

        stack.addArrangedSubview(header("Notes the planner keeps about you (edit freely, it reads this every time)"))
        notesView.isRichText = false
        notesView.font = .systemFont(ofSize: 13)
        notesView.delegate = self
        notesView.textContainerInset = NSSize(width: 6, height: 6)
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        let notesScroll = NSScrollView()
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesView.autoresizingMask = [.width]
        notesScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        stack.addArrangedSubview(notesScroll)
        let notesRow = NSStackView(views: [NSButton(title: "Save Notes", target: self, action: #selector(saveNotes)), notesSaved])
        notesRow.orientation = .horizontal
        notesSaved.textColor = .secondaryLabelColor
        stack.addArrangedSubview(notesRow)

        stack.addArrangedSubview(header("How each app's windows are arranged (learned from your moves)"))
        configure(stylesTable, columns: [("App", 300), ("Style", 140)])
        stack.addArrangedSubview(scroll(stylesTable, height: 120))
        let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
        addButton.addItem(withTitle: "Add running app…")
        addButton.target = self
        addButton.action = #selector(addStyle(_:))
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, let name = app.localizedName {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = id
                addButton.menu?.addItem(item)
            }
        }
        let stylesRow = NSStackView(views: [addButton, NSButton(title: "Remove Selected", target: self, action: #selector(removeStyle))])
        stylesRow.orientation = .horizontal
        stack.addArrangedSubview(stylesRow)

        stack.addArrangedSubview(header("Your corrections after arrangements (newest first)"))
        configure(correctionsTable, columns: [("When", 110), ("App", 110), ("Window", 180), ("Planned → You moved to", 220)])
        stack.addArrangedSubview(scroll(correctionsTable, height: 110))
        let correctionsRow = NSStackView(views: [
            NSButton(title: "Clear Corrections", target: self, action: #selector(clearCorrections)),
            NSButton(title: "Reset All Learning…", target: self, action: #selector(resetAll)),
        ])
        correctionsRow.orientation = .horizontal
        stack.addArrangedSubview(correctionsRow)

        stack.addArrangedSubview(header("Recent arrangements"))
        configure(arrangementsTable, columns: [("When", 110), ("Planner", 130), ("What happened", 380)])
        stack.addArrangedSubview(scroll(arrangementsTable, height: 120))

        for view in stack.arrangedSubviews {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
        }
        return stack
    }

    private func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func configure(_ table: NSTableView, columns: [(String, CGFloat)]) {
        for (title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
    }

    private func scroll(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case stylesTable: styles.count
        case correctionsTable: corrections.count
        default: arrangements.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }

        if tableView == stylesTable, column == "Style" {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.isBordered = false
            for option in Self.styleOptions {
                popup.addItem(withTitle: option.rawValue)
            }
            popup.selectItem(withTitle: styles[row].style.rawValue)
            popup.tag = row
            popup.target = self
            popup.action = #selector(styleChanged(_:))
            return popup
        }

        let text: String
        switch tableView {
        case stylesTable:
            text = "\(name(for: styles[row].bundleID))  (\(styles[row].bundleID))"
        case correctionsTable:
            let c = corrections[row]
            switch column {
            case "When": text = Self.dateFormatter.string(from: c.date)
            case "App": text = c.app
            case "Window": text = c.title
            default: text = "\(c.planned.w)×\(c.planned.h) @ \(c.planned.x),\(c.planned.y) → \(c.actual.w)×\(c.actual.h) @ \(c.actual.x),\(c.actual.y)"
            }
        default:
            let a = arrangements[row]
            switch column {
            case "When": text = Self.dateFormatter.string(from: a.date)
            case "Planner": text = a.planner + (a.durationMs.map { " (\($0) ms)" } ?? "")
            default: text = a.summary
            }
        }

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        return label
    }

    // MARK: - Actions

    @objc private func saveNotes() {
        model.arranger.setNotes(notesView.string)
        notesSaved.stringValue = "Saved \(Self.dateFormatter.string(from: Date()))"
    }

    func textDidChange(_ notification: Notification) {
        notesSaved.stringValue = "Unsaved changes"
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard sender.tag < styles.count, let title = sender.titleOfSelectedItem, let style = ArrangementStyle(rawValue: title) else { return }
        model.arranger.setAppStyle(style, for: styles[sender.tag].bundleID)
    }

    @objc private func addStyle(_ sender: NSPopUpButton) {
        guard let bundleID = sender.selectedItem?.representedObject as? String else { return }
        model.arranger.setAppStyle(.tiled, for: bundleID)
    }

    @objc private func removeStyle() {
        let row = stylesTable.selectedRow
        guard row >= 0, row < styles.count else { return }
        model.arranger.setAppStyle(nil, for: styles[row].bundleID)
    }

    @objc private func clearCorrections() {
        model.arranger.clearCorrections()
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all learning?"
        alert.informativeText = "Notes, app styles, corrections and the arrangement history will be deleted. The next arrangement starts from scratch."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.arranger.resetLearning()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.arranger.onHistoryChange = nil
        model.profileDidClose()
    }
}

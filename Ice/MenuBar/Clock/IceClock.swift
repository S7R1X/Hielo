//
//  IceClock.swift
//  Ice
//

import AppKit
import Combine

/// A clock in the menu bar that shows the date, and optionally the time, the way macOS's
/// own clock did ("Mié 4 nov  5:22 p. m."), as an item of Ice.
///
/// macOS 27 keeps its own clock on the bar whatever the user does: it cannot be
/// dragged, and Control Center turns its visibility preference back on (both measured
/// on macOS 27.0.1). Ice's clock can be turned off in the settings and, like any single
/// item, hidden behind macOS's own "«" button with ⌘ Command + drag. Ice cannot move
/// it to one of its own sections: on macOS 27 Ice hides whole applications, and the
/// clock belongs to Ice.
@MainActor
final class IceClock: NSObject {
    /// What the clock shows.
    struct Format: Equatable {
        var showsDayOfWeek: Bool
        var showsDate: Bool
        var showsTime: Bool
        var showsSeconds: Bool

        /// Whether any part of the date is shown. With nothing chosen at all, the clock
        /// still shows the date rather than an empty item.
        var showsDatePart: Bool {
            showsDayOfWeek || showsDate || !showsTime
        }
    }

    /// The autosave name of the clock's status item, which keeps its position on the bar.
    static let autosaveName = "Ice.Clock"

    /// The size of the clock's text. Measured on macOS 27.0.1 against the time shown by
    /// iStat Menus beside it, on a 2x display: iStat's digits are 22 px high, and the clock
    /// drew 20 px at the menu bar font's 13 pt and 21 px at 14.5 pt.
    private static let fontSize: CGFloat = 15

    /// Moves the clock's text down to sit on the same baseline as iStat's: at the default
    /// position it ended 2 px (1 pt) above it.
    private static let baselineOffset: CGFloat = -1

    private weak var appState: AppState?
    private var statusItem: NSStatusItem?
    private var appearanceObservation: NSKeyValueObservation?
    private var format = Format(showsDayOfWeek: true, showsDate: true, showsTime: true, showsSeconds: false)
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let dateFormatter = DateFormatter()
    private let timeFormatter = DateFormatter()

    /// The font of the clock, with digits of one width so it does not shift as the time
    /// changes.
    private let font = NSFont.monospacedDigitSystemFont(ofSize: IceClock.fontSize, weight: .regular)

    /// Starts following the clock settings.
    func performSetup(with appState: AppState) {
        self.appState = appState
        let general = appState.settings.general

        Publishers.CombineLatest4(
            general.$iceClockShowsDayOfWeek,
            general.$iceClockShowsDate,
            general.$iceClockShowsTime,
            general.$iceClockShowsSeconds
        )
        .map { Format(showsDayOfWeek: $0, showsDate: $1, showsTime: $2, showsSeconds: $3) }
        .combineLatest(general.$showIceClock)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] format, isShown in
            self?.apply(isShown: isShown, format: format)
        }
        .store(in: &cancellables)

        // A change of the clock, the time zone, the language or region (which also holds
        // the 12- or 24-hour preference) or the day, and waking from sleep, each leave the
        // shown date or its format stale until the next tick, so they redraw it at once.
        let names: [Notification.Name] = [
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification,
            .NSCalendarDayChanged,
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refresh(reformat: true)
                }
                .store(in: &cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh(reformat: false)
            }
            .store(in: &cancellables)
    }

    // MARK: Status Item

    private func apply(isShown: Bool, format: Format) {
        self.format = format
        guard isShown else {
            removeStatusItem()
            return
        }
        if statusItem == nil {
            createStatusItem()
        }
        refresh(reformat: true)
    }

    private func createStatusItem() {
        let autosaveName = Self.autosaveName
        // As for Ice's own icons, the item is allowed in the menu bar before it exists:
        // macOS 26 and later keep an item off the bar until its "VisibleCC" key is set.
        if ControlItemDefaults[.visible, autosaveName] == nil {
            ControlItemDefaults[.visible, autosaveName] = true
        }
        if #available(macOS 26.0, *), ControlItemDefaults[.visibleCC, autosaveName] == nil {
            ControlItemDefaults[.visibleCC, autosaveName] = true
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosaveName
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        // The menu bar turns light or dark with the wallpaper, and the text's colour with it.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh(reformat: false)
            }
        }
    }

    private func removeStatusItem() {
        tickTimer?.invalidate()
        tickTimer = nil
        appearanceObservation = nil
        guard let statusItem else {
            return
        }
        // Removing a status item deletes its preferred position, so it is kept and restored
        // (see `ControlItem.removeStatusItem`), and the clock comes back where it was.
        let autosaveName = Self.autosaveName
        let cachedPosition = ControlItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        ControlItemDefaults[.preferredPosition, autosaveName] = cachedPosition
        self.statusItem = nil
    }

    // MARK: Time

    /// Redraws the clock and schedules the next redraw, at the start of the next minute, or
    /// second when seconds are shown. A one-shot timer set for each tick stays on the minute
    /// whatever happens in between: sleep, a changed clock or a late run loop.
    private func refresh(reformat: Bool) {
        guard let button = statusItem?.button else {
            return
        }
        if reformat {
            configureFormatters()
        }
        let now = Date()
        // A solid colour rather than the menu bar's vibrant text, which drew the clock grey
        // (brightness 230) beside the white (247) of other items' text, as in iStat Menus.
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.attributedTitle = NSAttributedString(
            string: text(for: now),
            attributes: [
                .font: font,
                .foregroundColor: isDark ? NSColor.white : NSColor.black,
                .baselineOffset: Self.baselineOffset,
            ]
        )
        button.setAccessibilityLabel(DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: format.showsTime ? .short : .none))
        scheduleNextTick(after: now)
    }

    private func scheduleNextTick(after now: Date) {
        tickTimer?.invalidate()
        let unit: TimeInterval = format.showsTime && format.showsSeconds ? 1 : 60
        let seconds = now.timeIntervalSinceReferenceDate
        // A hair past the boundary, so the formatted time has already turned over.
        let next = Date(timeIntervalSinceReferenceDate: (seconds / unit).rounded(.down) * unit + unit + 0.02)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(reformat: false)
            }
        }
        timer.tolerance = unit == 1 ? 0.05 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// The language and region macOS's own clock uses: the user's first preferred language,
    /// not Ice's. An app formats dates in its own localization, so Ice showed "Wed 4 Nov" to
    /// a user whose Mac is in Spanish.
    private static var systemLocale: Locale {
        guard let language = Locale.preferredLanguages.first else {
            return .autoupdatingCurrent
        }
        var components = Locale.Components(identifier: language)
        if components.region == nil {
            components.region = Locale.autoupdatingCurrent.region
        }
        return Locale(components: components)
    }

    /// Sets the formatters from templates, so the order of the parts, the month names and
    /// the 12- or 24-hour clock ("j") all follow the user's language and region.
    private func configureFormatters() {
        let locale = Self.systemLocale
        dateFormatter.locale = locale
        timeFormatter.locale = locale
        var dateTemplate = ""
        if format.showsDayOfWeek {
            dateTemplate += "EEE"
        }
        if format.showsDate || !(format.showsDayOfWeek || format.showsTime) {
            dateTemplate += "dMMM"
        }
        if !dateTemplate.isEmpty {
            dateFormatter.setLocalizedDateFormatFromTemplate(dateTemplate)
        }
        timeFormatter.setLocalizedDateFormatFromTemplate(format.showsSeconds ? "jmmss" : "jmm")
    }

    private func text(for date: Date) -> String {
        var parts = [String]()
        if format.showsDatePart {
            // macOS's clock reads "Mié 4 nov": no commas, and the first letter capitalized.
            let datePart = dateFormatter.string(from: date).replacingOccurrences(of: ",", with: "")
            parts.append(datePart.prefix(1).uppercased() + datePart.dropFirst())
        }
        if format.showsTime {
            parts.append(timeFormatter.string(from: date))
        }
        return parts.joined(separator: "  ")
    }

    // MARK: Actions

    @objc private func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openDateAndTimeSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openIceSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
    }
}

// MARK: - IceClock: NSMenuDelegate

extension IceClock: NSMenuDelegate {
    /// Builds the menu each time it opens, so the full date in it is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let formatter = DateFormatter()
        formatter.locale = Self.systemLocale
        formatter.dateStyle = .full
        let fullDate = formatter.string(from: Date())
        let header = NSMenuItem(title: fullDate.prefix(1).uppercased() + fullDate.dropFirst(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for (title, action) in [
            (String(localized: "Open Calendar"), #selector(openCalendar)),
            (String(localized: "Date & Time Settings…"), #selector(openDateAndTimeSettings)),
            (String(localized: "Hielo Settings…"), #selector(openIceSettings)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }
}

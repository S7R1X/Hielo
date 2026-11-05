//
//  ItemImageStore27.swift
//  Ice
//

import AppKit
import OSLog
import ScreenCaptureKit

/// Images of menu bar items on macOS 27, captured from the active menu bar.
///
/// MenuBarAgent draws every item into one menu bar, so Ice's per-item window captures
/// are gone. Only a capture of the display holds the glyphs (measured on macOS 27.0: a
/// capture of MenuBarAgent's bar window holds just the application menu), and it
/// includes the bar's background. That background is cut away, leaving the glyph on
/// transparency, so the Ice Bar and the layout window draw every item on their own
/// colour whatever is behind the menu bar. Items on an inactive bar are drawn dimmer, so
/// only the active bar is captured. Images are kept on disk, so an item that is concealed
/// still has one.
@available(macOS 27.0, *)
@MainActor
final class ItemImageStore27 {
    typealias CapturedImage = MenuBarItemImageCache.CapturedImage

    private struct IndexEntry: Codable {
        let fileName: String
        let scale: CGFloat
        /// When the item was last seen on the bar (see `ItemImageRetention27`). Missing from
        /// indexes written before it was kept.
        var lastSeen: Date?
    }

    /// Bumped when stored images change shape. Version 1 kept the menu bar behind the
    /// glyph; version 2 cut it away but left the glyph in the colour it was captured in;
    /// version 3 kept the bar's own uneven padding around it; versions 4 and 5 left a haze
    /// of the bar over the tile, which showed as a pale box behind the glyph; version 6
    /// spaced the glyphs more tightly than the menu bar does; version 7 could not give a
    /// glyph its full margin when the capture ended right at the glyph's edge; version 8
    /// could store a tile cut while the bar was re-laying out; version 9 cut glyphs out of a
    /// capture of the display, which lost dim marks and colour (version 10 cuts them out of
    /// MenuBarAgent's backing window when it can).
    private static let storeVersion = "10"

    /// The margin left on each side of a glyph, in points, so items are spaced evenly and
    /// with the menu bar's own rhythm: its glyphs sit 18 to 29 points apart, median 22
    /// (measured on macOS 27.0), which is twice this margin.
    private nonisolated static let glyphMargin: CGFloat = 11

    private let logger = Logger(category: "ItemImageStore27")
    private nonisolated static let processingLogger = Logger(category: "ItemImageStore27")
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hielo/ItemImages", isDirectory: true)
    private var index = [String: IndexEntry]()
    private var loaded = [String: CapturedImage]()
    /// A hash of each glyph stored since launch, so an unchanged one is not stored again.
    private var digests = [String: Int]()
    private var photoSchedule = PhotoSchedule27()

    /// The capture under way, so captures follow one another instead of overlapping.
    private var captureTask: Task<Void, Never>?

    /// Counts the captures started, so only the last one clears ``captureTask``.
    private var captureGeneration = 0

    /// When the last capture finished, so a fresh one is not taken of an unchanged bar.
    private var lastCaptureFinishedAt: ContinuousClock.Instant?

    /// How long the images just captured stand before the bar is worth capturing again.
    private static let captureFreshness = Duration.milliseconds(700)

    private var appearanceObserver: NSObjectProtocol?

    /// The display last captured, as ScreenCaptureKit describes it.
    private var shareableDisplay: SCDisplay?
    /// MenuBarAgent's backing window last captured, as ScreenCaptureKit describes it. Kept
    /// for the same reason as ``shareableDisplay``: listing every window, off-screen ones
    /// included, is the expensive part of a capture.
    private var backingWindow: SCWindow?
    private var screenObserver: NSObjectProtocol?

    init() {
        // A display whose mode changed can keep its frame and change its scale.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shareableDisplay = nil
                self?.backingWindow = nil
            }
        }
        // Glyphs are stored in the colour that suits the current appearance, so a switch
        // between light and dark needs them captured again. Observed before the store is
        // read: a store that is reset below would otherwise never be told.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: DistributedNotificationCenter.interfaceThemeChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.discardImages()
            }
        }
        let versionFile = directory.appendingPathComponent("version.txt")
        guard (try? String(contentsOf: versionFile, encoding: .utf8)) == Self.storeVersion else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        if
            let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
            let stored = try? JSONDecoder().decode([String: IndexEntry].self, from: data)
        {
            // An entry from before sightings were noted counts as seen now.
            let now = Date()
            index = stored.mapValues { entry in
                var entry = entry
                entry.lastSeen = entry.lastSeen ?? now
                return entry
            }
        }
    }

    /// Drops every stored image, so they are captured again.
    private func discardImages() {
        loaded.removeAll()
        index.removeAll()
        digests.removeAll()
        photoSchedule = PhotoSchedule27()
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The stored image of the given item, if there is one.
    func image(for item: MenuBarItem) -> CapturedImage? {
        let key = item.tag.description
        if let image = loaded[key] {
            return image
        }
        guard
            let entry = index[key],
            let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(entry.fileName) as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let image = CapturedImage(cgImage: cgImage, scale: entry.scale)
        loaded[key] = image
        return image
    }

    /// Captures the active menu bar and stores the images of the items drawn on it.
    /// Captures follow one another rather than overlapping: a single reveal set four of them
    /// going at once, 260–290 ms each (measured 2026-09-16), all asking the display server
    /// for the same strip while MenuBarAgent was animating the bar.
    func captureActiveMenuBar(appState: AppState, force: Bool = false) async {
        if !force {
            // A capture already under way photographs the same bar this caller wants.
            if let captureTask {
                await captureTask.value
                return
            }
            // And one that has just been taken still describes it.
            if let last = lastCaptureFinishedAt, ContinuousClock.now - last < Self.captureFreshness {
                return
            }
        }
        captureGeneration += 1
        let generation = captureGeneration
        let previous = captureTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performCapture(appState: appState)
        }
        captureTask = task
        await task.value
        if captureGeneration == generation {
            captureTask = nil
        }
    }

    private func performCapture(appState: AppState) async {
        // The bar animates for about 250 ms after concealment changes. A capture taken then
        // photographs items in mid-slide, which are thrown away as unsettled anyway, and adds
        // its own load at the moment the animation can least afford it.
        if let remaining = appState.concealer27.timeUntilSettled() {
            try? await Task.sleep(for: remaining)
        }
        let started = ProcessInfo.processInfo.systemUptime
        logger.debug("Menu bar capture: started")
        defer {
            lastCaptureFinishedAt = .now
            logger.debug("Menu bar capture: took \((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public) ms")
        }
        guard
            ScreenCapture.cachedCheckPermissions(),
            let displayID = Bridging.getActiveMenuBarDisplayID(),
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }
        let displayBounds = CGDisplayBounds(displayID)
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 22)
        let displayStrip = CGRect(x: displayBounds.minX, y: displayBounds.minY, width: displayBounds.width, height: barHeight)
        let items = await MenuBarItemProvider27.items()
        let concealedPIDs = appState.concealer27.concealedPIDs
        // MenuBarAgent's backing window holds the glyphs on their own transparency and in
        // their own colours. A capture of the display, with the wallpaper behind the bar to
        // cut away, is the fallback for when that window cannot be found or captured.
        let strip: CGImage
        let scale: CGFloat
        let stripFrame: CGRect
        let fromBackingWindow: Bool
        if let backing = await captureBackingWindow(displayBounds: displayBounds) {
            strip = backing.image
            scale = backing.scale
            stripFrame = backing.frame
            fromBackingWindow = true
        } else if let captured = await captureStrip(displayID: displayID, size: displayStrip.size) {
            strip = captured.0
            scale = captured.1
            stripFrame = displayStrip
            fromBackingWindow = false
        } else {
            return
        }
        logger.debug("Menu bar capture: from \(fromBackingWindow ? "the backing window" : "the display", privacy: .public)")
        // Only items that sat still through the capture are stored. See `settledTags`.
        func frames(_ items: [MenuBarItem]) -> [String: CGRect] {
            Dictionary(items.map { ($0.tag.description, $0.bounds) }, uniquingKeysWith: { first, _ in first })
        }
        let settled = ItemImages27.settledTags(before: frames(items), after: frames(await MenuBarItemProvider27.items()))
        let drawn = items.filter { $0.isOnScreen && !$0.isControlItem && !concealedPIDs.contains($0.ownerPID) }
        let tiles = drawn
            .filter { settled.contains($0.tag.description) }
            .map { Tile(key: $0.tag.description, frame: $0.bounds) }
        let skipped = drawn.count - tiles.count
        let colour = Self.glyphColor()
        let known = digests
        // Cutting the glyphs out and encoding them is pixel work on every item of the bar, done
        // on every capture. It runs off the main thread, which the Ice Bar is being drawn on.
        let panelIsDark = colour.r == 255
        let processed = await Task.detached(priority: .userInitiated) {
            if fromBackingWindow {
                return Self.processBackingTiles(tiles, strip: strip, stripFrame: stripFrame, scale: scale, panelIsDark: panelIsDark, knownDigests: known)
            }
            return Self.processTiles(tiles, strip: strip, stripFrame: stripFrame, scale: scale, colour: colour, knownDigests: known)
        }.value
        var stored = 0
        for tile in processed where store(tile, scale: scale) {
            stored += 1
        }
        // Concealed items are read too, at the frames they were last drawn at, so they
        // count as seen and keep their images.
        let noted = noteSightings(of: items.map(\.tag.description))
        let pruned = pruneExpiredImages()
        if stored > 0 || noted || pruned {
            writeIndex()
        }
        logger.debug(
            """
            Stored \(stored, privacy: .public) changed item images of \(processed.count, privacy: .public) \
            from display \(displayID, privacy: .public), skipped \(skipped, privacy: .public) that moved
            """
        )
    }

    /// An item to cut out of a capture of the bar.
    private struct Tile: Sendable {
        let key: String
        let frame: CGRect
    }

    /// A glyph cut out of a capture of the bar.
    private struct ProcessedTile: @unchecked Sendable {
        let key: String
        let image: CGImage
        let digest: Int
        /// Whether the glyph differs from the one stored for the item.
        let isChanged: Bool
        /// The glyph encoded for the disk, if it changed.
        let png: Data?
    }

    /// Cuts the glyph of each tile out of the strip, and encodes the ones that changed.
    private nonisolated static func processTiles(
        _ tiles: [Tile],
        strip: CGImage,
        stripFrame: CGRect,
        scale: CGFloat,
        colour: (r: UInt8, g: UInt8, b: UInt8),
        knownDigests: [String: Int]
    ) -> [ProcessedTile] {
        let crops = tiles.compactMap { tile -> (key: String, image: CGImage)? in
            guard
                let rect = ItemImages27.cropRect(itemFrame: tile.frame, stripFrame: stripFrame, scale: scale),
                let crop = strip.cropping(to: rect)
            else {
                return nil
            }
            return (tile.key, crop)
        }
        // MenuBarAgent draws every glyph on a bar in one colour, white or black. Deciding which
        // for the whole strip, rather than tile by tile, keeps a dark patch of wallpaper behind
        // one item from passing for its glyph (see `ItemImages27.toneVotes`).
        var votes = (light: 0, dark: 0)
        for crop in crops {
            guard let pixels = pixels(of: crop.image) else {
                continue
            }
            let tileVotes = ItemImages27.toneVotes(pixels: pixels, width: crop.image.width, height: crop.image.height)
            votes.light += tileVotes.light
            votes.dark += tileVotes.dark
        }
        let tone: ItemImages27.GlyphTone? = votes.light + votes.dark == 0 ? nil : (votes.light >= votes.dark ? .light : .dark)
        return crops.compactMap { crop in
            guard let glyph = withoutBackground(crop.image, scale: scale, tone: tone, colour: colour) else {
                return nil
            }
            let digest = digest(of: glyph, scale: scale)
            // Most captures find every glyph as it was, and encoding and writing each of them
            // again every few seconds was wasted work.
            guard knownDigests[crop.key] != digest else {
                return ProcessedTile(key: crop.key, image: glyph, digest: digest, isChanged: false, png: nil)
            }
            let png = NSBitmapImageRep(cgImage: glyph).representation(using: .png, properties: [:])
            return ProcessedTile(key: crop.key, image: glyph, digest: digest, isChanged: true, png: png)
        }
    }

    /// Cuts the glyph of each tile out of a capture of MenuBarAgent's backing window, and
    /// encodes the ones that changed. The capture already holds each glyph on its own
    /// transparency, so nothing is cut away and no faint mark is dropped: colourless ink is
    /// only inverted when it would not read on the panel, and coloured marks are kept.
    private nonisolated static func processBackingTiles(
        _ tiles: [Tile],
        strip: CGImage,
        stripFrame: CGRect,
        scale: CGFloat,
        panelIsDark: Bool,
        knownDigests: [String: Int]
    ) -> [ProcessedTile] {
        let crops = tiles.compactMap { tile -> (key: String, width: Int, height: Int, pixels: [UInt8])? in
            guard
                let rect = ItemImages27.cropRect(itemFrame: tile.frame, stripFrame: stripFrame, scale: scale),
                let crop = strip.cropping(to: rect),
                let pixels = pixels(of: crop)
            else {
                return nil
            }
            return (tile.key, crop.width, crop.height, ItemImages27.unpremultiplied(pixels: pixels))
        }
        // MenuBarAgent draws all of a bar's template glyphs in one tone, so the tone is
        // judged over every tile at once.
        var votes = (light: 0, dark: 0)
        for crop in crops {
            let tileVotes = ItemImages27.inkVotes(straightPixels: crop.pixels)
            votes.light += tileVotes.light
            votes.dark += tileVotes.dark
        }
        let inkIsLight = votes.light >= votes.dark
        return crops.compactMap { crop in
            if ItemImages27.isFadedInBackingWindow(pixels: crop.pixels, width: crop.width, height: crop.height) {
                processingLogger.debug("Refusing a backing window tile of an item caught mid-fade")
                return nil
            }
            let adapted = ItemImages27.adaptingInk(straightPixels: crop.pixels, inkIsLight: inkIsLight, panelIsDark: panelIsDark)
            guard let glyph = paddedGlyph(
                premultipliedPixels: ItemImages27.premultiplied(pixels: adapted),
                width: crop.width,
                height: crop.height,
                scale: scale
            ) else {
                return nil
            }
            let digest = digest(of: glyph, scale: scale)
            guard knownDigests[crop.key] != digest else {
                return ProcessedTile(key: crop.key, image: glyph, digest: digest, isChanged: false, png: nil)
            }
            let png = NSBitmapImageRep(cgImage: glyph).representation(using: .png, properties: [:])
            return ProcessedTile(key: crop.key, image: glyph, digest: digest, isChanged: true, png: png)
        }
    }

    /// The glyph in the premultiplied pixels, trimmed to its own columns and given the even
    /// margin of ``glyphMargin``, or `nil` when the pixels hold nothing.
    private nonisolated static func paddedGlyph(premultipliedPixels pixels: [UInt8], width: Int, height: Int, scale: CGFloat) -> CGImage? {
        guard let columns = ItemImages27.glyphColumns(pixels: pixels, width: width, height: height) else {
            return nil
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let full = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }
        let margin = Int((glyphMargin * scale).rounded())
        let glyphWidth = columns.upperBound - columns.lowerBound + 1
        let paddedWidth = glyphWidth + margin * 2
        guard
            let glyph = full.cropping(to: CGRect(x: columns.lowerBound, y: 0, width: glyphWidth, height: height)),
            let padded = CGContext(
                data: nil,
                width: paddedWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: paddedWidth * 4,
                space: space,
                bitmapInfo: bitmapInfo
            )
        else {
            return full
        }
        padded.draw(glyph, in: CGRect(x: margin, y: 0, width: glyphWidth, height: height))
        return padded.makeImage() ?? full
    }

    /// A hash of the image's pixels, to tell whether a glyph changed since it was stored.
    private nonisolated static func digest(of image: CGImage, scale: CGFloat) -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        hasher.combine(scale)
        if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(data)))
        }
        return hasher.finalize()
    }

    /// Shows the applications of items that have no image for a moment, and captures them.
    func photographMissing(items: [MenuBarItem], appState: AppState) async {
        let now = ProcessInfo.processInfo.systemUptime
        let sourceBundleIDs = MenuBarItem.sourceBundleIDs(of: items)
        let bundleIDs = Set(items.compactMap { item -> String? in
            guard !item.isControlItem, image(for: item) == nil else {
                return nil
            }
            return item.sourcePID.flatMap { sourceBundleIDs[$0] }
        })
        .filter { photoSchedule.mayPhotograph(bundleID: $0, now: now) }
        guard !bundleIDs.isEmpty else {
            return
        }
        // One application at a time, waiting for each capture before revealing the next.
        // Revealed together (measured 2026-09-17) thirteen items no longer fitted the narrow
        // built-in bar and macOS folded nine of them into its own overflow, where they cannot
        // be photographed at all. Revealed in a burst without waiting, they were caught
        // mid-fade instead: the concealment applies behind them were still landing a second
        // and a half later, long after the capture judged the bar settled.
        for bundleID in bundleIDs.sorted().prefix(Self.photographsPerPass) {
            appState.concealer27.showTemporarily(bundleID: bundleID)
            // A shown item is drawn 0.4–0.6 s after its application is allowed (measured).
            try? await Task.sleep(for: .milliseconds(600))
            // Forced: this capture is the point of having shown the application at all, so it
            // must not be answered by one taken before the item appeared.
            await captureActiveMenuBar(appState: appState, force: true)
            appState.concealer27.endTemporaryShow(bundleID: bundleID)
            // Only an application that came away with an image counts as photographed. One
            // whose tile was refused, or whose item macOS folded away, would otherwise wait
            // out the full ten minutes with no glyph at all in the Ice Bar.
            photoSchedule.recordAttempt(
                bundleID: bundleID,
                now: ProcessInfo.processInfo.systemUptime,
                stored: hasImage(forBundleID: bundleID)
            )
        }
    }

    /// How many applications one pass photographs, so a first run does not spend a minute
    /// revealing items one after another.
    private static let photographsPerPass = 6

    /// Whether any of the application's items has a stored image.
    private func hasImage(forBundleID bundleID: String) -> Bool {
        index.keys.contains { $0.hasPrefix(bundleID + ":") }
    }

    // MARK: Private

    /// A capture of MenuBarAgent's backing window for the bar on the given display, with
    /// the window's frame in global points, or `nil` if the window cannot be found or
    /// captured. The window is off screen, so it is only listed when off-screen windows are.
    private func captureBackingWindow(displayBounds: CGRect) async -> (image: CGImage, scale: CGFloat, frame: CGRect)? {
        guard let target = Self.backingWindowInfo(displayBounds: displayBounds) else {
            backingWindow = nil
            return nil
        }
        do {
            let window: SCWindow
            if let cached = backingWindow, cached.windowID == target.windowID {
                window = cached
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let found = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    return nil
                }
                window = found
                backingWindow = found
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            // The frame is read again each time, so a bar that changed height is captured whole.
            configuration.width = Int(target.frame.width * scale)
            configuration.height = Int(target.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, scale, target.frame)
        } catch {
            backingWindow = nil
            logger.error("Could not capture MenuBarAgent's backing window: \(error, privacy: .public)")
            return nil
        }
    }

    /// The number and current frame, in global points, of MenuBarAgent's backing window for
    /// the bar on the given display: its window as wide as the display and no taller than a
    /// menu bar.
    private nonisolated static func backingWindowInfo(displayBounds: CGRect) -> (windowID: CGWindowID, frame: CGRect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windows where info[kCGWindowOwnerName as String] as? String == "MenuBarAgent" {
            guard
                let number = info[kCGWindowNumber as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                frame.height > 0,
                frame.height <= 60,
                frame.width >= displayBounds.width * 0.9,
                frame.intersects(displayBounds)
            else {
                continue
            }
            return (CGWindowID(number), frame)
        }
        return nil
    }

    private func captureStrip(displayID: CGDirectDisplayID, size: CGSize) async -> (CGImage, CGFloat)? {
        do {
            // Listing the shareable content asks the window server for every window, so the
            // display it names is kept until a capture of it fails or the display changes.
            let display: SCDisplay
            if let cached = shareableDisplay, cached.displayID == displayID, cached.frame == CGDisplayBounds(displayID) {
                display = cached
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let found = content.displays.first(where: { $0.displayID == displayID }) else {
                    return nil
                }
                display = found
                shareableDisplay = found
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(origin: .zero, size: size)
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, scale)
        } catch {
            shareableDisplay = nil
            logger.error("Could not capture the menu bar: \(error, privacy: .public)")
            return nil
        }
    }

    /// The colour glyphs are drawn in, which is the readable one on the flat background
    /// the Ice Bar and the layout window use.
    private static func glyphColor() -> (r: UInt8, g: UInt8, b: UInt8) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? (255, 255, 255) : (0, 0, 0)
    }

    /// The image's pixels, four bytes each, as the image rules expect them.
    private nonisolated static func pixels(of image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }

    /// The image with the menu bar behind the glyph made transparent, the glyph recoloured
    /// for the panel, and the bar's own padding replaced by an even margin.
    private nonisolated static func withoutBackground(
        _ image: CGImage,
        scale: CGFloat,
        tone: ItemImages27.GlyphTone?,
        colour: (r: UInt8, g: UInt8, b: UInt8)
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        let count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: count)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Array(UnsafeBufferPointer(start: bytes, count: count))
        let background = ItemImages27.backgroundColor(pixels: pixels, width: width, height: height)
        let removed = ItemImages27.removingBackground(pixels: pixels, width: width, height: height, background: background, tone: tone)
        // An item caught mid-fade cannot be rescued by any background estimate: what is left
        // is a faint glyph inside a wide haze of bar, and storing it is what made the Ice
        // Bar's icons pale and too wide. Refuse the tile; the item is photographed again
        // later, standing still. This comes before faint marks are dropped, or a faded glyph
        // would be dropped whole and stored as an empty tile.
        if ItemImages27.isFaded(pixels: removed, width: width, height: height) {
            processingLogger.debug("Refusing a tile of an item caught mid-fade")
            return nil
        }
        // Wallpaper detail in the glyph's own colour survives the colour test; marks that
        // never reach solid are dropped whole, so the trim below does not keep them either.
        // The bitmap holds premultiplied colours, so each channel follows the new opacity.
        var keyed = ItemImages27.premultiplied(pixels: ItemImages27.tinted(
            pixels: ItemImages27.droppingFaintMarks(pixels: removed, width: width, height: height),
            colour: colour
        ))
        keyed.withUnsafeMutableBytes { buffer in
            bytes.update(from: buffer.bindMemory(to: UInt8.self).baseAddress!, count: count)
        }
        guard
            let keyedImage = context.makeImage(),
            let columns = ItemImages27.glyphColumns(pixels: keyed, width: width, height: height)
        else {
            // Nothing was drawn in the item's rectangle; there is no image to keep.
            return nil
        }
        // The glyph is drawn into a fresh tile rather than cropped with margins, because a
        // capture often ends right at the glyph's edge and then cropping has no room left.
        let margin = Int((glyphMargin * scale).rounded())
        let glyphWidth = columns.upperBound - columns.lowerBound + 1
        let paddedWidth = glyphWidth + margin * 2
        guard
            let glyph = keyedImage.cropping(to: CGRect(x: columns.lowerBound, y: 0, width: glyphWidth, height: height)),
            let padded = CGContext(
                data: nil,
                width: paddedWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: paddedWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else {
            return keyedImage
        }
        padded.draw(glyph, in: CGRect(x: margin, y: 0, width: glyphWidth, height: height))
        return padded.makeImage() ?? keyedImage
    }

    /// Keeps a glyph cut from a capture, returning whether it changed.
    private func store(_ tile: ProcessedTile, scale: CGFloat) -> Bool {
        guard tile.isChanged else {
            return false
        }
        let key = tile.key
        let fileName = ItemImages27.fileName(forTag: key)
        loaded[key] = CapturedImage(cgImage: tile.image, scale: scale)
        index[key] = IndexEntry(fileName: fileName, scale: scale, lastSeen: Date())
        digests[key] = tile.digest
        guard let data = tile.png else {
            return true
        }
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
        return true
    }

    /// Notes that the items with the given keys are on the bar, returning whether the
    /// index changed.
    private func noteSightings(of keys: [String]) -> Bool {
        let now = Date()
        var changed = false
        for key in keys {
            guard
                var entry = index[key],
                entry.lastSeen.map({ ItemImageRetention27.needsRefresh(lastSeen: $0, now: now) }) ?? true
            else {
                continue
            }
            entry.lastSeen = now
            index[key] = entry
            changed = true
        }
        return changed
    }

    /// Drops the images of items not seen for a long time, returning whether any were.
    private func pruneExpiredImages() -> Bool {
        let now = Date()
        let expired = index.filter { _, entry in
            entry.lastSeen.map { ItemImageRetention27.isExpired(lastSeen: $0, now: now) } ?? false
        }
        guard !expired.isEmpty else {
            return false
        }
        for key in expired.keys {
            index[key] = nil
            loaded[key] = nil
            digests[key] = nil
        }
        let files = expired.values.map { directory.appendingPathComponent($0.fileName) }
        Task.detached(priority: .utility) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        logger.info("Dropped \(expired.count, privacy: .public) images of items not seen for a long time")
        return true
    }

    private func writeIndex() {
        guard let data = try? JSONEncoder().encode(index) else {
            return
        }
        let directory = directory
        let version = Self.storeVersion
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            try? version.write(to: directory.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        }
    }
}

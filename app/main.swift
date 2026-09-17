import AppKit
import CoreGraphics
import Darwin

// A native menu-bar companion, inspired by AeroSpace's i3Ordered style.
// No window management, global shortcuts, or Space-changing private API calls.
struct SpaceInfo: Codable, Equatable {
    let id: UInt64
    let index: Int
    let display: Int
    let fullscreen: Bool
    let focused: Bool
    let visible: Bool
    var apps: [String: Int]
}

struct Snapshot: Codable, Equatable {
    let source: String
    let spaces: [SpaceInfo]
    let note: String?
    var desktopCount: Int { spaces.filter { !$0.fullscreen }.count }
    var fullscreenCount: Int { spaces.filter { $0.fullscreen }.count }
}

enum ReadError: Error { case unavailable, invalidData }

func yabaiExecutable() -> String? {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["YABAI_BIN"] {
        return FileManager.default.isExecutableFile(atPath: override) ? override : nil
    }
    let candidates = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
        + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/yabai" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func command(_ arguments: [String]) throws -> Data {
    guard let binary = yabaiExecutable() else { throw ReadError.unavailable }
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: binary)
    task.arguments = ["-m"] + arguments
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    // Drain stdout while the process runs; bound unresponsive daemons to 3 seconds.
    let done = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in done.signal() }
    try task.run()
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if task.isRunning { task.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    _ = done.wait(timeout: .now() + 3)
    guard !task.isRunning, task.terminationStatus == 0 else { throw ReadError.unavailable }
    return data
}

func yabaiSnapshot() throws -> Snapshot {
    let spacesData = try command(["query", "--spaces"])
    let windowsData = try command(["query", "--windows"])
    return try decodeYabai(spacesData: spacesData, windowsData: windowsData)
}

func decodeYabai(spacesData: Data, windowsData: Data) throws -> Snapshot {
    guard let rows = try JSONSerialization.jsonObject(with: spacesData) as? [[String: Any]],
          !rows.isEmpty else { throw ReadError.invalidData }
    guard let windows = try JSONSerialization.jsonObject(with: windowsData) as? [[String: Any]]
    else { throw ReadError.invalidData }
    let spaces = rows.compactMap { row -> SpaceInfo? in
        guard let id = row["id"] as? NSNumber, let index = row["index"] as? Int,
              let display = row["display"] as? Int else { return nil }
        let ids = Set(row["windows"] as? [Int] ?? [])
        var apps: [String: Int] = [:]
        for window in windows {
            guard let wid = window["id"] as? Int, ids.contains(wid),
                  let app = window["app"] as? String, !app.isEmpty,
                  window["role"] as? String == "AXWindow" else { continue }
            apps[app, default: 0] += 1
        }
        return SpaceInfo(id: id.uint64Value, index: index, display: display,
                         fullscreen: row["is-native-fullscreen"] as? Bool ?? false,
                         focused: row["has-focus"] as? Bool ?? false,
                         visible: row["is-visible"] as? Bool ?? false, apps: apps)
    }.sorted { $0.index < $1.index }
    guard spaces.count == rows.count else { throw ReadError.invalidData }
    return Snapshot(source: "yabai", spaces: spaces, note: nil)
}

// Read-only fallback using the same WindowServer query APIs as yabai. Symbols
// are resolved dynamically; failure is reported instead of force-unwrapping.
final class NativeSpaces {
    typealias Connection = @convention(c) () -> Int32
    typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias ActiveDisplay = @convention(c) (Int32) -> Unmanaged<CFString>?
    typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let handle: UnsafeMutableRawPointer
    private let connection: Connection
    private let displays: Displays
    private let activeDisplay: ActiveDisplay
    private let windowSpaces: WindowSpaces

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        else { throw ReadError.unavailable }
        guard let connection = dlsym(handle, "SLSMainConnectionID"),
              let displays = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let active = dlsym(handle, "SLSCopyActiveMenuBarDisplayIdentifier"),
              let windows = dlsym(handle, "SLSCopySpacesForWindows") else {
            dlclose(handle)
            throw ReadError.unavailable
        }
        self.handle = handle
        self.connection = unsafeBitCast(connection, to: Connection.self)
        self.displays = unsafeBitCast(displays, to: Displays.self)
        self.activeDisplay = unsafeBitCast(active, to: ActiveDisplay.self)
        self.windowSpaces = unsafeBitCast(windows, to: WindowSpaces.self)
    }

    deinit { dlclose(handle) }

    func snapshot() throws -> Snapshot {
        let cid = connection()
        guard let raw = displays(cid)?.takeRetainedValue() as? [[String: Any]], !raw.isEmpty
        else { throw ReadError.unavailable }
        let active = activeDisplay(cid)?.takeRetainedValue() as String?
        var spaces: [SpaceInfo] = []
        for (displayIndex, display) in raw.enumerated() {
            let uuid = display["Display Identifier"] as? String
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber
            for row in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = row["id64"] as? NSNumber else { continue }
                let visible = id == current
                spaces.append(SpaceInfo(id: id.uint64Value, index: spaces.count + 1,
                                        display: displayIndex + 1,
                                        fullscreen: (row["type"] as? Int ?? 0) != 0,
                                        focused: visible && (uuid == active || raw.count == 1),
                                        visible: visible, apps: [:]))
            }
        }
        guard !spaces.isEmpty else { throw ReadError.invalidData }
        // Use app metadata only; never retain window titles or capture images.
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let regularPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.map { $0.processIdentifier })
        var appsBySpace: [UInt64: [String: Int]] = [:]
        for window in windows {
            guard let wid = window[kCGWindowNumber as String] as? NSNumber,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32, regularPIDs.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let name = window[kCGWindowOwnerName as String] as? String, !name.isEmpty,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) > 32, (bounds["Height"] as? Double ?? 0) > 32,
                  let ids = windowSpaces(cid, 7, [wid] as CFArray)?.takeRetainedValue() as? [NSNumber]
            else { continue }
            for sid in ids { appsBySpace[sid.uint64Value, default: [:]][name, default: 0] += 1 }
        }
        for index in spaces.indices { spaces[index].apps = appsBySpace[spaces[index].id] ?? [:] }
        return Snapshot(source: "macOS fallback", spaces: spaces,
                        note: "yabai is unavailable; showing native macOS desktops. App lists may omit hidden or minimized windows.")
    }
}

func readSnapshot() -> Snapshot {
    if let snapshot = try? yabaiSnapshot() { return snapshot }
    if let snapshot = try? NativeSpaces().snapshot() { return snapshot }
    return Snapshot(source: "unavailable", spaces: [],
                    note: "Could not read desktops. Check yabai and Displays have separate Spaces.")
}

func symbolName(_ space: SpaceInfo) -> String {
    return "\(space.index).square" + (space.focused ? ".fill" : "")
}

func indicatorImage(_ spaces: [SpaceInfo]) -> NSImage {
    let height: CGFloat = 20
    let gap: CGFloat = 3
    let widths = spaces.map { max(height, CGFloat(String($0.index).count) * 8 + 8) }
    let width = widths.reduce(0, +) + CGFloat(max(0, spaces.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(20, width), height: height), flipped: false) { rect in
        var x: CGFloat = 0
        for (index, space) in spaces.enumerated() {
            let box = NSRect(x: x, y: 0, width: widths[index], height: height)
            let opacity: CGFloat = space.visible ? 1 : 0.5
            if let symbol = NSImage(systemSymbolName: symbolName(space), accessibilityDescription: nil) {
                let configured = symbol.withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) ?? symbol
                configured.draw(in: box, from: .zero, operation: .sourceOver, fraction: opacity)
            } else {
                NSColor.black.withAlphaComponent(opacity).set()
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
                path.lineWidth = 1.5
                if space.focused { path.fill() } else { path.stroke() }
                let text = String(space.index) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.black.withAlphaComponent(opacity)]
                let size = text.size(withAttributes: attributes)
                NSGraphicsContext.saveGraphicsState()
                if space.focused { NSGraphicsContext.current?.compositingOperation = .destinationOut }
                text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
            }
            x += widths[index] + gap
        }
        return true
    }
    image.isTemplate = true
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var busy = false
    private var snapshot = Snapshot(source: "loading", spaces: [], note: nil)
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "…"
        item.button?.setAccessibilityLabel("Yabai Spaces")
        item.menu = menu
        menu.delegate = self
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        refresh()
    }

    @objc func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let result = readSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.busy = false
                if self.snapshot != result {
                    self.snapshot = result
                    self.updateIndicator()
                }
            }
        }
    }

    private func updateIndicator() {
        guard let button = item.button else { return }
        if snapshot.spaces.isEmpty {
            button.image = NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "Desktops unavailable")
            button.title = ""
        } else {
            button.title = ""
            button.image = indicatorImage(snapshot.spaces)
        }
        let current = snapshot.spaces.filter { $0.focused }.map { String($0.index) }.joined(separator: ", ")
        button.toolTip = "\(snapshot.desktopCount) desktops · Current: \(current.isEmpty ? "unknown" : current)\nClick for apps on each desktop"
        button.setAccessibilityValue(button.toolTip)
        // Small local diagnostics file for checking the running app, not telemetry.
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/local.davidpurvis.yabaispaces")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let diagnostic: [String: Any] = ["source": snapshot.source,
                                       "spaceIndices": snapshot.spaces.map { $0.index },
                                       "focusedIndices": snapshot.spaces.filter { $0.focused }.map { $0.index },
                                       "statusItemVisible": item.isVisible,
                                       "imageWidth": button.image?.size.width ?? 0,
                                       "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: cache.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refresh()
    }

    private func heading(_ title: String, to menu: NSMenu) {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        menu.addItem(row)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let count = "\(snapshot.desktopCount) desktop\(snapshot.desktopCount == 1 ? "" : "s")"
        let full = snapshot.fullscreenCount == 0 ? "" : " · \(snapshot.fullscreenCount) fullscreen"
        heading("Yabai Spaces · " + count + full, to: menu)
        menu.addItem(.separator())
        var lastDisplay: Int?
        let multipleDisplays = Set(snapshot.spaces.map { $0.display }).count > 1
        for space in snapshot.spaces {
            if multipleDisplays && space.display != lastDisplay {
                if lastDisplay != nil { menu.addItem(.separator()) }
                heading("Display \(space.display)", to: menu)
                lastDisplay = space.display
            }
            let names = space.apps.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let summary = names.isEmpty ? "No app windows reported" : names.joined(separator: ", ")
            let truncated = summary.count > 64 ? String(summary.prefix(61)) + "…" : summary
            let title = "\(space.index)\(space.fullscreen ? " [fullscreen]" : "") — \(truncated)"
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.state = space.focused ? .on : .off
            let detail = NSMenu()
            heading("\(space.fullscreen ? "Fullscreen Space" : "Desktop") \(space.index)\(space.focused ? " · Current" : "")", to: detail)
            if names.isEmpty { heading("No app windows reported", to: detail) }
            for name in names {
                let n = space.apps[name] ?? 0
                let appItem = NSMenuItem(title: "\(name) · \(n) window\(n == 1 ? "" : "s")", action: nil, keyEquivalent: "")
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let icon = app.icon {
                    let small = icon.copy() as! NSImage
                    small.size = NSSize(width: 16, height: 16)
                    appItem.image = small
                }
                detail.addItem(appItem)
            }
            row.submenu = detail
            menu.addItem(row)
        }
        menu.addItem(.separator())
        heading("Data: \(snapshot.source)", to: menu)
        if let note = snapshot.note {
            let title = snapshot.spaces.isEmpty ? "Desktop data unavailable" : "yabai unavailable — native desktop view"
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.toolTip = note
            menu.addItem(row)
        }
        for (title, action) in [("Refresh", #selector(refresh)),
                                ("Open reference guide", #selector(openGuide)),
                                ("Quit Yabai Spaces", #selector(quit))] {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
            row.target = self
            menu.addItem(row)
        }
    }

    @objc private func openGuide() {
        if let guide = Bundle.main.url(forResource: "Reference", withExtension: "md") {
            NSWorkspace.shared.open(guide)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
Yabai Spaces 1.0.0
Usage: YabaiSpaces [--snapshot | --self-test | --render-preview PATH | --help | --version]
Without arguments, starts the native menu-bar indicator.
--snapshot        Read desktop/app metadata as JSON (no window titles).
--self-test       Run deterministic checks without querying live desktops.
--render-preview  Render live desktop numbers to a PNG (not a screenshot).
"""
if arguments == ["--help"] {
    print(usage)
    exit(0)
}
if arguments == ["--version"] {
    print("1.0.0")
    exit(0)
}
let validArguments = arguments.isEmpty || arguments == ["--snapshot"]
    || arguments == ["--self-test"]
    || (arguments.count == 2 && arguments.first == "--render-preview")
if !validArguments {
    fputs(usage + "\nInvalid arguments.\n", stderr)
    exit(2)
}

if arguments == ["--snapshot"] {
    let snapshot = readSnapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
    exit(snapshot.spaces.isEmpty ? 1 : 0)
}

if arguments == ["--self-test"] {
    var spaces: [SpaceInfo] = []
    for index in 1...4 {
        let apps: [String: Int] = index == 1 ? ["Terminal": 2] : [:]
        let space = SpaceInfo(id: UInt64(index), index: index, display: 1,
                              fullscreen: index == 4, focused: index == 2,
                              visible: index == 2, apps: apps)
        spaces.append(space)
    }
    precondition(symbolName(spaces[0]) == "1.square")
    precondition(symbolName(spaces[1]) == "2.square.fill")
    let fixture = Snapshot(source: "test", spaces: spaces, note: nil)
    precondition(fixture.desktopCount == 3 && fixture.fullscreenCount == 1)
    precondition(indicatorImage(spaces).size == NSSize(width: 89, height: 20))
    precondition(indicatorImage(spaces).isTemplate)
    let roundTrip = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(fixture))
    precondition(roundTrip == fixture)
    let spaceJSON = Data("""
    [{"id": 92, "index": 2, "display": 2, "is-native-fullscreen": true,
      "has-focus": true, "is-visible": true, "windows": [22, 23]},
     {"id": 91, "index": 1, "display": 1, "is-native-fullscreen": false,
      "has-focus": false, "is-visible": true, "windows": [21, 23]}]
    """.utf8)
    let windowJSON = Data("""
    [{"id": 21, "app": "Terminal", "role": "AXWindow", "title": "Ignored private title"},
     {"id": 22, "app": "Safari", "role": "AXWindow"},
     {"id": 23, "app": "Notes", "role": "AXWindow"},
     {"id": 24, "app": "Unrelated", "role": "AXWindow"}]
    """.utf8)
    let decoded = try decodeYabai(spacesData: spaceJSON, windowsData: windowJSON)
    precondition(decoded.spaces.map { $0.index } == [1, 2])
    precondition(decoded.spaces[0].apps == ["Terminal": 1, "Notes": 1])
    precondition(decoded.spaces[1].apps == ["Safari": 1, "Notes": 1])
    precondition(decoded.spaces[0].visible && !decoded.spaces[0].focused)
    precondition(decoded.spaces[1].display == 2 && decoded.spaces[1].focused)
    precondition(decoded.desktopCount == 1 && decoded.fullscreenCount == 1)
    let encoded = try JSONEncoder().encode(decoded)
    precondition(!String(data: encoded, encoding: .utf8)!.contains("Ignored private title"))
    for invalid in ["[]", "[{}]", "{}"] {
        do {
            _ = try decodeYabai(spacesData: Data(invalid.utf8), windowsData: windowJSON)
            preconditionFailure("Invalid Space data accepted")
        } catch ReadError.invalidData { }
    }
    print("Passed: symbols, counts, geometry, template rendering, JSON round-trip, multi-display membership, title exclusion, invalid data.")
    exit(0)
}

if let argument = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.count > argument + 1 {
    let snapshot = readSnapshot()
    let indicator = indicatorImage(snapshot.spaces)
    let size = NSSize(width: indicator.size.width + 24, height: 36)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3),
                                 pixelsHigh: Int(size.height * 3), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.cgContext.scaleBy(x: 3, y: 3)
    NSColor(white: 0.94, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    indicator.draw(in: NSRect(x: 12, y: 8, width: indicator.size.width, height: indicator.size.height))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[argument + 1]))
    print("Rendered actual desktop indicator to " + CommandLine.arguments[argument + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

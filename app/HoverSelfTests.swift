import AppKit

private final class FakeHoverDaemon {
    var mode: HoverMode = .off
    var pid = "first-daemon"
    var available = true
    var rejectWrite = false
    var ignoreWrite = false
    var failReadback = false
    var readsToFail = 0
    var saved: Bool?
    var saves: [Bool] = []
    var writes: [String] = []

    func run(_ args: [String]) throws -> Data {
        guard available else { throw ReadError.unavailable }
        precondition(Array(args.prefix(2)) == ["config", "focus_follows_mouse"])
        if args.count == 3 {
            writes.append(args[2])
            if rejectWrite { throw ReadError.unavailable }
            if !ignoreWrite { mode = HoverMode(rawValue: args[2])! }
            if failReadback { readsToFail = 1 }
            return Data()
        }
        if readsToFail > 0 {
            readsToFail -= 1
            throw ReadError.unavailable
        }
        return Data((mode == .off ? "disabled\n" : mode.rawValue + "\n").utf8)
    }

    func controller() -> HoverFocusController {
        return HoverFocusController(run: { try self.run($0) }, identity: { self.pid },
                                    load: { self.saved }, save: { self.saved = $0; self.saves.append($0) })
    }
}

private final class HoverMenuTestTarget: NSObject {
    let controller: HoverFocusController
    var result: HoverStatus?
    init(_ controller: HoverFocusController) { self.controller = controller }
    @objc func toggle(_ sender: NSMenuItem) { result = controller.toggle() }
}

func runHoverSelfTests() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    for (text, expected) in [("disabled\n", HoverMode.off), ("off", .off),
                             ("autofocus\n", .autofocus), ("autoraise", .autoraise)] {
        let parsed = try HoverMode(response: Data(text.utf8))
        precondition(parsed == expected)
    }
    do {
        _ = try HoverMode(response: Data("unexpected".utf8))
        preconditionFailure("Unrecognized setting accepted")
    } catch HoverError.invalidResponse { }

    let daemon = FakeHoverDaemon()
    let controller = daemon.controller()
    precondition(controller.refresh().title == "Focus on hover: Disabled")
    precondition(daemon.saved == nil && daemon.writes.isEmpty)
    let target = HoverMenuTestTarget(controller)
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = hoverMenuItem(controller.refresh(), changing: false, target: target,
                             action: #selector(HoverMenuTestTarget.toggle(_:)))
    menu.addItem(item)
    precondition(item.isEnabled && item.state == .off)
    menu.performActionForItem(at: 0)
    precondition(target.result?.title == "Focus on hover: Enabled")
    precondition(daemon.saved == true && daemon.writes == ["autofocus"])
    menu.performActionForItem(at: 0)
    precondition(target.result?.title == "Focus on hover: Disabled")
    precondition(daemon.saved == false && daemon.writes == ["autofocus", "off"])

    daemon.mode = .autoraise
    precondition(controller.refresh().title == "Focus on hover: Enabled")
    precondition(daemon.writes.count == 2 && daemon.saved == false)
    precondition(controller.toggle().mode == .off)

    let enabled = hoverMenuItem(HoverStatus(mode: .autofocus, error: nil), changing: false, target: nil, action: nil)
    precondition(enabled.title == "Focus on hover: Enabled" && enabled.state == .on)
    let pending = hoverMenuItem(HoverStatus(mode: .off, error: nil), changing: true, target: nil, action: nil)
    precondition(!pending.isEnabled)
    let unavailable = hoverMenuItem(HoverStatus(mode: nil, error: "Unavailable"), changing: false, target: nil, action: nil)
    precondition(!unavailable.isEnabled && unavailable.title == "Focus on hover: Unavailable")

    let restarted = FakeHoverDaemon()
    restarted.saved = true
    let restartController = restarted.controller()
    precondition(restartController.refresh().mode == .autofocus)
    precondition(restarted.writes == ["autofocus"] && restarted.saves.isEmpty)
    restarted.mode = .off
    precondition(restartController.refresh().mode == .off)
    precondition(restarted.writes.count == 1) // Respect external changes on the same daemon.
    restarted.pid = "second-daemon"
    precondition(restartController.refresh().mode == .autofocus)
    precondition(restarted.writes.count == 2)
    restarted.available = false
    precondition(restartController.refresh().mode == nil)
    restarted.mode = .off
    restarted.available = true
    precondition(restartController.refresh().mode == .autofocus)
    precondition(restarted.writes.count == 3)
    restarted.mode = .off
    let newApp = restarted.controller()
    precondition(newApp.refresh().mode == .autofocus)

    let disabled = FakeHoverDaemon()
    disabled.saved = false
    disabled.mode = .autoraise
    precondition(disabled.controller().refresh().mode == .off)
    precondition(disabled.writes == ["off"])

    for failure in ["rejected", "mismatch", "readback", "unavailable"] {
        let broken = FakeHoverDaemon()
        let brokenController = broken.controller()
        _ = brokenController.refresh()
        broken.rejectWrite = failure == "rejected"
        broken.ignoreWrite = failure == "mismatch"
        broken.failReadback = failure == "readback"
        broken.available = failure != "unavailable"
        let result = brokenController.toggle()
        precondition(result.error != nil && broken.saved == nil && broken.saves.isEmpty)
        if failure == "unavailable" { precondition(result.mode == nil && broken.writes.isEmpty) }
    }
    let failedRestore = FakeHoverDaemon()
    failedRestore.saved = true
    failedRestore.rejectWrite = true
    let recovering = failedRestore.controller()
    precondition(recovering.refresh().error != nil)
    precondition(failedRestore.saved == true)
    failedRestore.rejectWrite = false
    precondition(recovering.refresh().mode == .autofocus)
    print("Passed: hover menu actions, live-state parsing, saved choices, restarts/reconnects, external changes, and failed writes/readbacks.")
}

// Explicit opt-in smoke test. Normal --self-test never touches a live daemon.
func runLiveHoverTest() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let original = try HoverMode(response: command(["config", "focus_follows_mouse"]))
    guard original == .off else { throw HoverError.notApplied }
    let defaults = UserDefaults.standard
    defer {
        _ = try? command(["config", "focus_follows_mouse", "off"])
        defaults.set(false, forKey: hoverPreferenceKey)
        defaults.synchronize()
    }
    let controller = HoverFocusController(load: { nil }, save: { defaults.set($0, forKey: hoverPreferenceKey) })
    let target = HoverMenuTestTarget(controller)
    let menu = NSMenu()
    menu.autoenablesItems = false
    let initial = controller.refresh()
    guard initial.mode == .off else { throw HoverError.notApplied }
    let item = hoverMenuItem(initial, changing: false, target: target,
                             action: #selector(HoverMenuTestTarget.toggle(_:)))
    menu.addItem(item)
    menu.performActionForItem(at: 0)
    guard target.result?.mode == .autofocus, target.result?.error == nil else { throw HoverError.notApplied }
    let enabled = try HoverMode(response: command(["config", "focus_follows_mouse"]))
    guard enabled == .autofocus else { throw HoverError.notApplied }
    menu.performActionForItem(at: 0)
    guard target.result?.mode == .off, target.result?.error == nil else { throw HoverError.notApplied }
    let disabled = try HoverMode(response: command(["config", "focus_follows_mouse"]))
    guard disabled == .off, defaults.object(forKey: hoverPreferenceKey) as? Bool == false else {
        throw HoverError.notApplied
    }
    print("Passed: actual AppKit menu actions enabled and disabled live yabai; confirmed disabled and saved that choice.")
}

import AppKit
import Darwin

let hoverPreferenceKey = "focusOnHoverEnabled"

enum HoverMode: String {
    case off, autofocus, autoraise

    init(response: Data) throws {
        let text = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "off", "disabled": self = .off
        case "autofocus": self = .autofocus
        case "autoraise": self = .autoraise
        default: throw HoverError.invalidResponse
        }
    }

    var enabled: Bool { self != .off }
}

enum HoverError: Error {
    case invalidResponse, notApplied
}

struct HoverStatus: Equatable {
    var mode: HoverMode?
    var error: String?

    var title: String {
        guard let mode = mode else { return "Focus on hover: Unavailable" }
        return "Focus on hover: " + (mode.enabled ? "Enabled" : "Disabled")
    }
}

// Access only on the app's serial worker queue. Injected dependencies keep tests
// independent of real desktops, running daemons, and the user's preferences.
final class HoverFocusController {
    private let run: ([String]) throws -> Data
    private let identity: () -> String?
    private let load: () -> Bool?
    private let save: (Bool) -> Void
    private var connected = false
    private var previousIdentity: String?

    init(run: @escaping ([String]) throws -> Data = command,
         identity: @escaping () -> String? = yabaiDaemonIdentity,
         load: @escaping () -> Bool? = {
             UserDefaults.standard.object(forKey: hoverPreferenceKey) as? Bool
         },
         save: @escaping (Bool) -> Void = {
             UserDefaults.standard.set($0, forKey: hoverPreferenceKey)
         }) {
        self.run = run
        self.identity = identity
        self.load = load
        self.save = save
    }

    private func read() throws -> HoverMode {
        return try HoverMode(response: run(["config", "focus_follows_mouse"]))
    }

    private func apply(_ enabled: Bool) throws -> HoverMode {
        _ = try run(["config", "focus_follows_mouse", enabled ? "autofocus" : "off"])
        let confirmed = try read()
        guard confirmed.enabled == enabled else { throw HoverError.notApplied }
        return confirmed
    }

    func refresh() -> HoverStatus {
        let currentIdentity = identity()
        let live: HoverMode
        do {
            live = try read()
        } catch {
            connected = false
            return HoverStatus(mode: nil, error: "Cannot read hover focus. Check that yabai is running.")
        }
        let restore = !connected || (currentIdentity != nil && currentIdentity != previousIdentity)
        connected = true
        previousIdentity = currentIdentity
        if restore, let wanted = load(), wanted != live.enabled {
            do {
                return HoverStatus(mode: try apply(wanted), error: nil)
            } catch {
                // Retry restoration after reconnecting, but report only confirmed state.
                connected = false
                return HoverStatus(mode: try? read(), error: "Could not restore your saved hover-focus choice. Check yabai and try again.")
            }
        }
        return HoverStatus(mode: live, error: nil)
    }

    func toggle() -> HoverStatus {
        do {
            // Read again at click time; another tool may have changed the setting.
            let wanted = try !read().enabled
            let confirmed = try apply(wanted)
            save(wanted)
            connected = true
            previousIdentity = identity()
            return HoverStatus(mode: confirmed, error: nil)
        } catch {
            let confirmed = try? read()
            if confirmed == nil { connected = false }
            return HoverStatus(mode: confirmed, error: "Could not change hover focus. Check that yabai is running, then try again.")
        }
    }
}

func yabaiDaemonIdentity() -> String? {
    // yabai replaces its per-user IPC socket on restart. Identifying the socket
    // avoids mistaking short-lived `yabai -m` clients for new daemon processes.
    let path = "/tmp/yabai_\(NSUserName()).socket"
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let inode = attributes[.systemFileNumber] as? NSNumber,
          let created = attributes[.creationDate] as? Date else { return nil }
    return inode.stringValue + ":" + String(created.timeIntervalSince1970)
}

func hoverMenuItem(_ status: HoverStatus, changing: Bool, target: AnyObject?, action: Selector?) -> NSMenuItem {
    let row = NSMenuItem(title: status.title, action: action, keyEquivalent: "")
    row.target = target
    row.isEnabled = status.mode != nil && !changing
    row.state = status.mode?.enabled == true ? .on : .off
    row.toolTip = changing ? "Updating hover focus…" : status.error ?? "Click to toggle. Your choice is remembered across restarts."
    return row
}

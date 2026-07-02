import CoreAudio
import Foundation
import AppKit
import Darwin

/// An audio-producing app, used as a per-app capture source. One entry groups
/// ALL of the app's audio process objects (browsers play audio from helper
/// processes, so a single app can own several).
struct AudioProcess: Identifiable, Hashable {
    /// Stable app identity (the enclosing `.app` path, else bundle id).
    let id: String
    let name: String
    let bundleID: String?
    /// Representative pid, used for the icon fallback.
    let pid: pid_t
    /// Enclosing `.app` bundle path, if resolved.
    let appPath: String?
    /// Every Core Audio process object belonging to this app.
    let processObjectIDs: [AudioObjectID]

    static func == (l: AudioProcess, r: AudioProcess) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var icon: NSImage? {
        if let appPath { return NSWorkspace.shared.icon(forFile: appPath) }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }
}

enum AudioProcessManager {

    /// Every *app* currently producing output, with a friendly name. Helper
    /// processes are resolved to their real app and grouped; system daemons
    /// with no `.app` (e.g. com.apple.corespeech) and our own process are
    /// filtered out.
    static func runningOutputProcesses() -> [AudioProcess] {
        let objectIDs: [AudioObjectID] = AO.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        )
        let ownPID = getpid()

        struct Group { var name: String; var bundleID: String?; var pid: pid_t; var appPath: String?; var objs: [AudioObjectID] }
        var groups: [String: Group] = [:]

        for object in objectIDs {
            let isRunning = AO.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            guard isRunning != 0 else { continue }

            let pid = AO.scalar(object, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1
            guard pid > 0, pid != ownPID else { continue }

            let bundleID = AO.string(object, kAudioProcessPropertyBundleID)
            if let bundleID, bundleID.hasPrefix("com.soundsplitter") { continue }

            // Only surface things that resolve to a real .app (skips daemons).
            guard let resolved = resolveApp(pid: pid, bundleID: bundleID) else { continue }

            let key = resolved.appPath ?? bundleID ?? "pid:\(pid)"
            if groups[key] == nil {
                groups[key] = Group(name: resolved.name, bundleID: bundleID,
                                    pid: pid, appPath: resolved.appPath, objs: [object])
            } else {
                groups[key]?.objs.append(object)
            }
        }

        return groups.map { key, g in
            AudioProcess(id: key, name: g.name, bundleID: g.bundleID,
                         pid: g.pid, appPath: g.appPath, processObjectIDs: g.objs)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Name resolution

    private static func resolveApp(pid: pid_t, bundleID: String?) -> (name: String, appPath: String?)? {
        // A registered app (foreground or agent) with a proper localized name.
        if let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy != .prohibited,
           let name = app.localizedName {
            return (name, app.bundleURL?.path)
        }
        // A helper/child process: resolve via its executable path to the
        // outermost enclosing .app bundle (e.g. Brave's audio helper -> Brave).
        if let path = executablePath(pid), let enclosing = enclosingApp(path) {
            return enclosing
        }
        return nil
    }

    /// The outermost `.app` bundle in an executable path, plus its display name.
    private static func enclosingApp(_ path: String) -> (name: String, appPath: String)? {
        guard let range = path.range(of: ".app") else { return nil }
        let appPath = String(path[path.startIndex..<range.upperBound])
        let display = FileManager.default.displayName(atPath: appPath)
        let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        return (name.isEmpty ? nil : name).map { ($0, appPath) }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

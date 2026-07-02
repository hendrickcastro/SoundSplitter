import SwiftUI
import CoreAudio
import Combine
import AppKit

/// A source shown in the UI (system or a specific app), with display info.
struct DisplaySource: Identifiable {
    let key: SourceKey
    let title: String
    let subtitle: String?
    let appIcon: NSImage?
    let isPlaying: Bool
    var id: SourceKey { key }
}

/// UI-facing model. Holds the routing matrix (which source goes to which
/// outputs, at what volume) and drives the multi-source `AudioEngine`.
@MainActor
final class AppState: ObservableObject {

    @Published var outputDevices: [AudioDevice] = []
    /// Selected output devices per source.
    @Published var routing: [SourceKey: Set<AudioObjectID>] = [:]
    /// Per-source volume (0...1) and mute.
    @Published var volume: [SourceKey: Double] = [:]
    @Published var muted: [SourceKey: Bool] = [:]
    /// Routing is live as soon as a device is selected (no global start).
    /// Kept as a global kill-switch reachable from the right-click menu.
    @Published var masterEnabled = true
    @Published var statusMessage: String?

    @Published private(set) var activeApps: [AudioProcess] = []

    private let engine = AudioEngine()
    private var knownApps: [String: AudioProcess] = [:]
    private var knownDevices: [AudioObjectID: AudioDevice] = [:]
    private var refreshTimer: Timer?

    private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observeSleepWake()
        observeDeviceChanges()
    }

    /// React immediately when a device appears/disappears (e.g. Bluetooth
    /// headphones unplugged) instead of waiting for the 3 s timer.
    private func observeDeviceChanges() {
        var address = AO.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    // MARK: Discovery (off the main thread — CoreAudio reads can block)

    func refresh() {
        Task.detached(priority: .utility) { [weak self] in
            let apps = AudioProcessManager.runningOutputProcesses()
            let devices = AudioDeviceManager.outputDevices()
            await self?.apply(apps: apps, devices: devices)
        }
    }

    func refreshApps() { refresh() }
    func refreshDevices() { refresh() }

    private func apply(apps: [AudioProcess], devices: [AudioDevice]) {
        activeApps = apps
        outputDevices = devices
        for app in apps { knownApps[app.id] = app }
        // Devices are present-only (no accumulation) so a route can never point
        // at a device that has been unplugged.
        knownDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

        // A routed device disappeared (e.g. Bluetooth headphones removed):
        // prune it, and if that leaves a source with no output, fall back to
        // the current default output (the Mac speakers) so audio keeps playing
        // there automatically instead of going silent.
        let presentIDs = Set(devices.map(\.id))
        let defaultID = AudioDeviceManager.defaultOutputDeviceID
        var changed = false
        for (key, set) in Array(routing) {
            let survivors = set.intersection(presentIDs)
            guard survivors != set else { continue }
            changed = true
            if survivors.isEmpty, let defaultID, presentIDs.contains(defaultID) {
                routing[key] = [defaultID]           // fall back to Mac speakers
                Log.info("Salida perdida para \(key): fallback al dispositivo por defecto.")
            } else {
                routing[key] = survivors.isEmpty ? nil : survivors
            }
        }
        if changed { sync() }
    }

    // MARK: Sleep / wake

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }
    }

    private func handleSleep() {
        Log.info("Sistema va a suspenderse: liberando rutas de audio.")
        engine.stopAll()
    }

    private func handleWake() {
        Log.info("Sistema reanudado: refrescando dispositivos y reconstruyendo rutas.")
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.sync()
        }
    }

    // MARK: Sources shown in the UI

    var displaySources: [DisplaySource] {
        var sources: [DisplaySource] = [
            DisplaySource(key: .system, title: "Todo el sistema",
                          subtitle: "Todo el audio del Mac", appIcon: nil, isPlaying: true)
        ]
        let activeIDs = Set(activeApps.map(\.id))
        let configuredAppIDs = routing.keys.compactMap { key -> String? in
            if case .app(let id) = key { return id }
            return nil
        }
        let appSources = activeIDs.union(configuredAppIDs).compactMap { id -> DisplaySource? in
            guard let app = knownApps[id] else { return nil }
            return DisplaySource(key: .app(id), title: app.name, subtitle: app.bundleID,
                                 appIcon: app.icon, isPlaying: activeIDs.contains(id))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        sources.append(contentsOf: appSources)
        return sources
    }

    // MARK: Routing matrix

    func isEnabled(_ deviceID: AudioObjectID, for key: SourceKey) -> Bool {
        routing[key]?.contains(deviceID) ?? false
    }

    func enabledCount(for key: SourceKey) -> Int { routing[key]?.count ?? 0 }

    func volume(for key: SourceKey) -> Double { volume[key] ?? 1.0 }
    func isMuted(for key: SourceKey) -> Bool { muted[key] ?? false }

    func toggleOutput(_ deviceID: AudioObjectID, for key: SourceKey) {
        var set = routing[key] ?? []
        if set.contains(deviceID) { set.remove(deviceID) } else { set.insert(deviceID) }
        routing[key] = set.isEmpty ? nil : set
        sync()
    }

    func setVolume(_ value: Double, for key: SourceKey) {
        volume[key] = value
        sync()
    }

    func setMuted(_ value: Bool, for key: SourceKey) {
        muted[key] = value
        sync()
    }

    /// Short human description of where a source is routed, for the row subtitle.
    func routingDescription(for key: SourceKey) -> String {
        let ids = routing[key] ?? []
        switch ids.count {
        case 0: return "Sin salida"
        case 1:
            return ids.first.flatMap { knownDevices[$0]?.name } ?? "1 salida"
        default:
            return "Varias · \(ids.count) salidas"
        }
    }

    // MARK: Engine

    func toggleRunning() {
        masterEnabled.toggle()
        sync()
    }

    private func sync() {
        guard masterEnabled else {
            engine.stopAll()
            statusMessage = nil
            return
        }

        var plans: [SourcePlan] = []
        for (key, deviceIDs) in routing {
            let devices = deviceIDs.compactMap { knownDevices[$0] }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !devices.isEmpty else { continue }

            let source: RoutedSource.Source
            switch key {
            case .system:
                source = .systemWide
            case .app(let id):
                guard let app = knownApps[id] else { continue }
                source = .app(app)
            }
            plans.append(SourcePlan(key: key, source: source, outputs: devices,
                                    volume: Float(volume(for: key)), muted: isMuted(for: key)))
        }

        statusMessage = nil
        engine.sync(plans) { [weak self] _, message in
            Task { @MainActor in self?.statusMessage = message }
        }
    }

    var totalActiveRoutes: Int {
        masterEnabled ? routing.values.filter { !$0.isEmpty }.count : 0
    }
}

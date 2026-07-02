import CoreAudio
import AudioToolbox
import Foundation

/// Routes ONE source (system or a single app) to one or more output devices,
/// using the same technique as SoundSource / FineTune:
///
///   - A native process tap (`AudioHardwareCreateProcessTap`) captures the audio.
///   - A **private aggregate device** embeds that tap as a sub-tap AND all the
///     target output devices as sub-devices. When there is more than one output
///     the aggregate is *stacked*, so the HAL mirrors the audio to every device.
///   - A single real-time IOProc copies the tapped input to the aggregate's
///     outputs, applying a smoothly-ramped volume.
///   - **Clock drift is handled by CoreAudio itself** via drift-compensation
///     flags — no manual ring buffer, no sample dropping. That is what removes
///     the delay and the micro-dropouts of the previous design.
final class RoutedSource: @unchecked Sendable {

    enum Source {
        case systemWide
        case app(AudioProcess)
    }

    let key: SourceKey
    private let source: Source

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Tapped stream channel count (usually 2).
    private var inputChannels = 2

    // RT-thread volume state. Written from the main thread, read on the audio
    // thread; word-sized so tearing is harmless, and ramped to avoid clicks.
    private var targetVolume: Float = 1.0
    private var currentVolume: Float = 1.0
    private var rampCoefficient: Float = 0.002

    private(set) var outputUIDs: [String] = []

    init(key: SourceKey, source: Source) {
        self.key = key
        self.source = source
    }

    deinit { stop() }

    // MARK: Public control

    func setVolume(_ volume: Float, muted: Bool) {
        targetVolume = muted ? 0 : max(0, volume)
    }

    /// (Re)build the aggregate for the given ordered outputs. Passing a new set
    /// tears the old aggregate down and builds a fresh one.
    func setOutputs(_ devices: [AudioDevice]) -> Bool {
        let uids = devices.map(\.uid)
        if uids == outputUIDs && aggregateID != kAudioObjectUnknown { return true }
        teardownAggregate()
        guard !devices.isEmpty else { outputUIDs = []; return true }

        if tapID == kAudioObjectUnknown, !createTap() { return false }
        return buildAggregate(for: devices)
    }

    func stop() {
        teardownAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Tap

    private func createTap() -> Bool {
        let description: CATapDescription
        switch source {
        case .systemWide:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .app(let process):
            // Tap ALL of the app's audio process objects (browsers use helpers).
            description = CATapDescription(stereoMixdownOfProcesses: process.processObjectIDs)
        }
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "SoundSplitter Tap"
        description.isPrivate = true
        // Mute the source's normal output so our routed copy is what plays.
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            Log.error("createProcessTap fallo (\(key)): \(osStatusString(status))")
            return false
        }
        tapID = tap

        // Read the tapped format to know channel count and set the ramp.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AO.address(kAudioTapPropertyFormat)
        if AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr,
           asbd.mChannelsPerFrame > 0 {
            inputChannels = Int(asbd.mChannelsPerFrame)
            // 30 ms exponential ramp, like FineTune, to avoid volume-step clicks.
            let sr = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            rampCoefficient = Float(1 - exp(-1.0 / (sr * 0.030)))
        }
        return true
    }

    // MARK: Aggregate

    /// Order outputs so a non-Bluetooth device is the clock when possible
    /// (more stable clock, and lets us disable tap drift comp only for BT).
    private func buildAggregate(for devices: [AudioDevice]) -> Bool {
        let ordered = devices.sorted { !$0.isBluetooth && $1.isBluetooth }
        let clock = ordered[0]

        var subDevices: [[String: Any]] = []
        for (index, device) in ordered.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey as String: device.uid,
                // Clock (index 0) is the master; the rest resample toward it.
                kAudioSubDeviceDriftCompensationKey as String: index > 0,
            ])
        }

        // Disable tap drift comp when the clock is Bluetooth (shared clock
        // domain) — forcing it there causes a periodic crackle.
        let tapDriftCompensation = !clock.isBluetooth

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SoundSplitter \(key)",
            kAudioAggregateDeviceUIDKey as String: "com.soundsplitter.agg.\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: clock.uid,
            kAudioAggregateDeviceClockDeviceKey as String: clock.uid,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            // Stacked = HAL mirrors the audio to every sub-device.
            kAudioAggregateDeviceIsStackedKey as String: ordered.count > 1,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: tapDriftCompensation,
                kAudioSubTapUIDKey as String: tapUUID.uuidString,
            ]],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard createStatus == noErr, aggregate != kAudioObjectUnknown else {
            Log.error("createAggregate fallo (\(key)): \(osStatusString(createStatus))")
            return false
        }
        aggregateID = aggregate
        outputUIDs = ordered.map(\.uid)

        // Start volume from silence and ramp up to avoid a startup pop.
        currentVolume = 0

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregate, nil) {
            [weak self] _, inInputData, _, outOutputData, _ in
            self?.render(input: inInputData, output: outOutputData)
        }
        guard ioStatus == noErr else {
            Log.error("createIOProc fallo (\(key)): \(osStatusString(ioStatus))")
            teardownAggregate()
            return false
        }
        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            Log.error("AudioDeviceStart fallo (\(key)): \(osStatusString(startStatus))")
            teardownAggregate()
            return false
        }
        Log.info("Ruta activa \(key) → \(outputUIDs.count) salida(s), clock=\(clock.name), tapDrift=\(tapDriftCompensation)")
        return true
    }

    private func teardownAggregate() {
        if aggregateID != kAudioObjectUnknown {
            // Fade to silence before stopping so the cut is click-free and we
            // stop feeding new audio immediately (the residual you still hear
            // on Bluetooth is its own output buffer draining — inherent, not
            // something we can flush). Runs on the engine's background queue,
            // so this brief sleep never blocks the UI.
            let savedTarget = targetVolume
            if ioProcID != nil {
                targetVolume = 0
                usleep(50_000) // ~50 ms: the 30 ms ramp reaches near-silence
            }
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            // Restore intended volume so a rebuild (device change) ramps back up.
            targetVolume = savedTarget
        }
        outputUIDs = []
    }

    // MARK: Real-time render

    /// Copy the tapped input to every output channel, mirroring a stereo
    /// source across stacked devices, with a per-sample volume ramp.
    /// RT-safe: no allocation, no locks, no logging.
    private func render(input: UnsafePointer<AudioBufferList>,
                        output: UnsafeMutablePointer<AudioBufferList>) {
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)

        guard let inBuf = inABL.first, let inData = inBuf.mData else {
            zero(outABL); return
        }
        let inCh = max(1, Int(inBuf.mNumberChannels))
        let inPtr = inData.assumingMemoryBound(to: Float.self)
        let inFrames = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size / inCh

        let target = targetVolume
        let coef = rampCoefficient
        var vol = currentVolume

        // Walk output buffers; track a global output-channel index so we can
        // mirror input channel `g % inCh` into each output channel.
        var globalCh = 0
        for outBuf in outABL {
            guard let outData = outBuf.mData else { continue }
            let outCh = max(1, Int(outBuf.mNumberChannels))
            let outPtr = outData.assumingMemoryBound(to: Float.self)
            let outFrames = Int(outBuf.mDataByteSize) / MemoryLayout<Float>.size / outCh

            for frame in 0..<outFrames {
                // Ramp once per frame (cheap, click-free enough).
                vol += (target - vol) * coef
                for ch in 0..<outCh {
                    let srcCh = (globalCh + ch) % inCh
                    let sample = frame < inFrames ? inPtr[frame * inCh + srcCh] : 0
                    outPtr[frame * outCh + ch] = sample * vol
                }
            }
            globalCh += outCh
        }
        currentVolume = vol
    }

    private func zero(_ abl: UnsafeMutableAudioBufferListPointer) {
        for buf in abl {
            if let data = buf.mData {
                memset(data, 0, Int(buf.mDataByteSize))
            }
        }
    }
}

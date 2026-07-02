import CoreAudio
import Foundation

/// A hardware (or virtual) audio device capable of output.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    /// Number of output channels the device exposes.
    let outputChannels: Int
    /// CoreAudio transport type (`kAudioDeviceTransportType…`).
    let transportType: UInt32

    var isAggregate: Bool { name.contains("SoundSplitter") }

    /// Bluetooth devices add ~150-250 ms inherent latency and share a clock
    /// domain quirk; tap drift compensation must be gated off for them.
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioDeviceManager {

    /// The system-wide default output device (what "System Audio" plays to now).
    static var defaultOutputDeviceID: AudioObjectID? {
        AO.scalar(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        ).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func uid(of device: AudioObjectID) -> String? {
        AO.string(device, kAudioDevicePropertyDeviceUID)
    }

    /// All devices that can play audio out. Aggregate devices we created
    /// ourselves are filtered out so they don't pollute the picker.
    static func outputDevices() -> [AudioDevice] {
        let ids: [AudioObjectID] = AO.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices
        )
        return ids.compactMap { device -> AudioDevice? in
            let channels = outputChannelCount(device)
            guard channels > 0 else { return nil }
            let name = AO.string(device, kAudioObjectPropertyName) ?? "Unknown device"
            let uid = AO.string(device, kAudioDevicePropertyDeviceUID) ?? ""
            let transport = AO.scalar(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
            let dev = AudioDevice(id: device, uid: uid, name: name,
                                  outputChannels: channels, transportType: transport)
            return dev.isAggregate ? nil : dev
        }
    }

    /// Number of output channels by summing the output stream configuration.
    static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var address = AO.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Nominal sample rate for a device (defaults to 48k if unavailable).
    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        AO.scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 48_000
    }
}

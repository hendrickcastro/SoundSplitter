import CoreAudio
import Foundation

/// Thin, type-safe helpers over the C `AudioObjectGetPropertyData` API.
/// Every Core Audio property read boils down to filling an
/// `AudioObjectPropertyAddress` and calling into these functions.
enum AO {

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func hasProperty(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(id, &address)
    }

    /// Read a single fixed-size value (numbers, structs like ASBD).
    static func scalar<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        initial: T
    ) -> T? {
        var address = address(selector, scope: scope, element: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    /// Read a variable-length array of fixed-size values (device lists, etc.).
    static func array<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> [T] {
        var address = address(selector, scope: scope, element: element)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return []
        }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// Read a `CFString` property as a Swift `String`.
    static func string(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        var address = address(selector, scope: scope, element: element)
        var cfString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cfString else { return nil }
        return cfString as String
    }

    /// Translate a value through a property that takes an input qualifier
    /// (e.g. PID -> process AudioObjectID).
    static func translate<In, Out>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        input: In,
        initial: Out
    ) -> Out? {
        var address = address(selector)
        var input = input
        var output = initial
        var size = UInt32(MemoryLayout<Out>.size)
        let status = withUnsafeMutablePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                AudioObjectGetPropertyData(
                    id, &address,
                    UInt32(MemoryLayout<In>.size), inPtr,
                    &size, outPtr
                )
            }
        }
        return status == noErr ? output : nil
    }
}

/// Human-readable description for a Core Audio `OSStatus`, useful in logs.
func osStatusString(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    // Many Core Audio codes are FourCharCodes.
    let chars = [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
                 UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    if chars.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'\(String(bytes: chars, encoding: .ascii) ?? "?")' (\(status))"
    }
    return "\(status)"
}

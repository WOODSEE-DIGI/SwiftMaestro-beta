import Foundation
import CoreAudio

// MARK: - Audio device model

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

// MARK: - Audio device manager

/// Enumerates macOS CoreAudio input/output devices. Used by Whisper settings so
/// users can choose which microphone/interface Whisper records from and which
/// output device is used for playback/monitoring.
final class AudioDeviceManager: @unchecked Sendable {
    static let shared = AudioDeviceManager()

    var inputDevices: [AudioDevice] { allDevices.filter { $0.hasInput } }
    var outputDevices: [AudioDevice] { allDevices.filter { $0.hasOutput } }

    var allDevices: [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var result = AudioObjectGetPropertyDataSize(systemObject, &propertyAddress, 0, nil, &dataSize)
        guard result == noErr else { return [] }

        let deviceCount = Int(dataSize / UInt32(MemoryLayout<AudioDeviceID>.size))
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        result = AudioObjectGetPropertyData(systemObject, &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard result == noErr else { return [] }

        return deviceIDs.map { id in
            AudioDevice(
                id: id,
                name: deviceName(id: id),
                hasInput: deviceHasStreams(id: id, scope: kAudioDevicePropertyScopeInput),
                hasOutput: deviceHasStreams(id: id, scope: kAudioDevicePropertyScopeOutput)
            )
        }
    }

    // MARK: - Default devices

    var defaultInputDeviceID: AudioDeviceID? {
        getDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    var defaultOutputDeviceID: AudioDeviceID? {
        getDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - Validation

    /// Returns the device ID if it is still a valid current input device, otherwise nil.
    /// AudioDeviceID 0 is reserved for the system object and is never a valid device.
    func validInputDeviceID(_ id: AudioDeviceID?) -> AudioDeviceID? {
        guard let id, id != 0 else { return nil }
        return inputDevices.contains(where: { $0.id == id }) ? id : nil
    }

    /// Returns the device ID if it is still a valid current output device, otherwise nil.
    func validOutputDeviceID(_ id: AudioDeviceID?) -> AudioDeviceID? {
        guard let id, id != 0 else { return nil }
        return outputDevices.contains(where: { $0.id == id }) ? id : nil
    }

    @discardableResult
    func setDefaultInputDevice(id: AudioDeviceID) -> Bool {
        setDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice, id: id)
    }

    @discardableResult
    func setDefaultOutputDevice(id: AudioDeviceID) -> Bool {
        setDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice, id: id)
    }

    // MARK: - Mute / Volume

    func isMuted(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &muted)
        return result == noErr && muted != 0
    }

    @discardableResult
    func setMuted(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, muted: Bool) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let result = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return result == noErr
    }

    func volume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &volume)
        guard result == noErr else { return nil }
        return volume
    }

    @discardableResult
    func setVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, volume: Float) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = max(0, min(1, volume))
        let result = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        return result == noErr
    }

    // MARK: - Private

    private func getDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let result = AudioObjectGetPropertyData(systemObject, &propertyAddress, 0, nil, &size, &deviceID)
        return result == noErr ? deviceID : nil
    }

    private func setDefaultDevice(selector: AudioObjectPropertySelector, id: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let result = AudioObjectSetPropertyData(systemObject, &propertyAddress, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
        return result == noErr
    }

    private func deviceName(id: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, &name)
        guard result == noErr, let name = name else { return "Unknown Device" }
        return name.takeRetainedValue() as String
    }

    private func deviceHasStreams(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let result = AudioObjectGetPropertyDataSize(id, &propertyAddress, 0, nil, &dataSize)
        guard result == noErr else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        let result2 = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, buffer)
        guard result2 == noErr else { return false }

        let abl = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return abl.pointee.mNumberBuffers > 0
    }
}

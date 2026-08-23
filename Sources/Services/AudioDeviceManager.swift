import Foundation
import CoreAudio
import IOBluetooth

// MARK: - Audio device model

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    /// CoreAudio transport: 'blth'/'blua' Bluetooth, 'airp' AirPlay, etc.
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

// MARK: - Paired Bluetooth audio device model

/// A Bluetooth audio device paired with this Mac (pairing records sync via
/// iCloud), whether or not it is currently connected. Mirrors what the macOS
/// Sound menu shows; CoreAudio only lists these once they CONNECT.
struct PairedBluetoothAudioDevice: Identifiable, Hashable, Sendable {
    let address: String
    let name: String
    let isConnected: Bool
    var id: String { address }
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
            let transport = deviceTransportType(id: id)
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
            var hasInput = deviceHasStreams(id: id, scope: kAudioDevicePropertyScopeInput)
            var hasOutput = deviceHasStreams(id: id, scope: kAudioDevicePropertyScopeOutput)
            // Bluetooth headsets (AirPods etc.) can report zero streams while
            // idle — without this they'd vanish from both pickers even though
            // they're valid routes the moment audio starts.
            if isBluetooth {
                hasInput = true
                hasOutput = true
            }
            return AudioDevice(
                id: id,
                name: deviceName(id: id),
                hasInput: hasInput,
                hasOutput: hasOutput,
                transportType: transport
            )
        }
    }

    // MARK: - Paired Bluetooth audio devices

    /// Audio-class devices paired with this Mac (AirPods, BT speakers,
    /// headsets), connected or not. Pairing records come from iCloud sync,
    /// so AirPods "connected to my iPhone" still appear — tapping Connect
    /// opens the Bluetooth link, after which CoreAudio surfaces the device
    /// and the hot-plug listener refreshes the pickers.
    var pairedBluetoothAudioDevices: [PairedBluetoothAudioDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { device in
            // Major class 0x04 = Audio/Video (headphones, headsets, speakers).
            guard device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) else { return nil }
            return PairedBluetoothAudioDevice(
                address: device.addressString,
                name: device.name ?? device.addressString,
                isConnected: device.isConnected()
            )
        }
    }

    /// Open the Bluetooth link and wait (up to `timeout`) for CoreAudio to
    /// publish the device as a HAL output — BT negotiation takes a moment.
    /// Shared by Audio Control and the Media Player so both behave the same.
    @discardableResult
    func connectBluetoothAndAwaitDevice(_ device: PairedBluetoothAudioDevice, timeout: TimeInterval = 12) async -> AudioDevice? {
        if !device.isConnected {
            _ = connectBluetoothDevice(address: device.address)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = allDevices.first(where: { $0.name == device.name && $0.hasOutput }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// Open a Bluetooth connection to a paired device (equivalent to
    /// selecting it in the Sound menu). Returns true if the link opened.
    @discardableResult
    func connectBluetoothDevice(address: String) -> Bool {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = paired.first(where: { $0.addressString == address }) else { return false }
        if device.isConnected() { return true }
        return device.openConnection() == kIOReturnSuccess
    }

    // MARK: - Hot-plug notifications

    private let changeLock = NSLock()
    private var changeHandlers: [UUID: () -> Void] = [:]
    private var deviceListenerInstalled = false

    /// Register a handler fired on the main queue whenever the CoreAudio
    /// device list changes (Bluetooth connect/disconnect, USB plug, …).
    /// Returns a token; pass to `removeDevicesChangedHandler` to unsubscribe.
    @discardableResult
    func addDevicesChangedHandler(_ handler: @escaping () -> Void) -> UUID {
        installDeviceListenerIfNeeded()
        let token = UUID()
        changeLock.lock()
        changeHandlers[token] = handler
        changeLock.unlock()
        return token
    }

    func removeDevicesChangedHandler(_ token: UUID) {
        changeLock.lock()
        changeHandlers[token] = nil
        changeLock.unlock()
    }

    private func installDeviceListenerIfNeeded() {
        changeLock.lock()
        defer { changeLock.unlock() }
        guard !deviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated)
        ) { [weak self] _, _ in
            self?.notifyDevicesChanged()
        }
        deviceListenerInstalled = (status == noErr)
    }

    private func notifyDevicesChanged() {
        changeLock.lock()
        let handlers = Array(changeHandlers.values)
        changeLock.unlock()
        for handler in handlers {
            DispatchQueue.main.async(execute: handler)
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

    private func deviceTransportType(id: AudioDeviceID) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, &transport)
        return result == noErr ? transport : 0
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

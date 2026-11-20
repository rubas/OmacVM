import AudioToolbox
import CoreAudio

/// The Mac's sound output in CoreAudio, for what OmacVM Bridge's /audio does
/// not say: its left/right balance, the Balance slider of System Settings ›
/// Sound. A device has one only with a volume per channel: headphones and
/// most USB interfaces do, a display's speakers and AirPlay do not, and
/// macOS shows no slider then.
public enum SoundOutput {
    private static var balanceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static func device() -> AudioObjectID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// The output's CoreAudio UID, as the Bridge's /audio names it. AirPlay
    /// gets a new one each time it connects.
    public static var uid: String? {
        guard let device = device() else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &s) == noErr else { return nil }
        return s?.takeRetainedValue() as String?
    }

    /// 0 (left) ... 0.5 (centre) ... 1 (right), and whether it can be set.
    /// Nil: the output has no balance.
    public static var balance: (value: Double, settable: Bool)? {
        guard let device = device(), AudioObjectHasProperty(device, &balanceAddress) else { return nil }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size), settable: DarwinBoolean = false
        guard AudioObjectGetPropertyData(device, &balanceAddress, 0, nil, &size, &v) == noErr else { return nil }
        AudioObjectIsPropertySettable(device, &balanceAddress, &settable)
        return (Double(v), settable.boolValue)
    }

    /// False: the output has no balance, or one that cannot be set.
    public static func setBalance(_ value: Double) -> Bool {
        guard let device = device(), balance?.settable == true else { return false }
        var v = Float32(max(0, min(1, value)))
        return AudioObjectSetPropertyData(device, &balanceAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}

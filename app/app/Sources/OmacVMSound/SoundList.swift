import Foundation

/// One element of Control Center's Sound list, as Accessibility gives it.
public struct SoundElement: Equatable {
    public var depth: Int
    public var role, subrole, identifier, description, value: String
    public init(depth: Int, role: String, subrole: String = "", identifier: String = "", description: String = "", value: String = "") {
        self.depth = depth; self.role = role; self.subrole = subrole
        self.identifier = identifier; self.description = description; self.value = value
    }
}

/// A device in the list. `selected`: sound plays there (macOS's checkmark).
public struct SoundRow: Equatable {
    public var name: String
    public var selected: Bool
    public init(name: String, selected: Bool) { self.name = name; self.selected = selected }
}

/// What Control Center's Sound list says (SoundPicker reads it), without
/// Accessibility: the rules are tested on recorded lists (sound-tests).
public enum SoundList {
    /// The list's title, there only while the list shows.
    public static let title = "controlcenter-volume"
    /// A device's row: this prefix, then the device's name.
    public static let rowPrefix = "sound-device-"
    public static let rowRole = "AXCheckBox"

    public static func rows(_ elements: [SoundElement]) -> [SoundRow] {
        elements.compactMap { e in
            guard e.role == rowRole, e.identifier.hasPrefix(rowPrefix), e.identifier.count > rowPrefix.count else { return nil }
            return SoundRow(name: String(e.identifier.dropFirst(rowPrefix.count)), selected: e.value == "1")
        }
    }

    /// After a press of `name`: macOS is done once the row's checkmark
    /// differs from before, or once the list moved and is as before again
    /// (the speaker did not connect and macOS went back).
    public static func pressDone(_ name: String, before: [SoundRow], now: [SoundRow], moved: Bool) -> Bool {
        func selected(_ rows: [SoundRow]) -> Bool? { rows.first { $0.name == name }?.selected }
        if let was = selected(before), let isNow = selected(now), was != isNow { return true }
        return moved && now == before
    }
}

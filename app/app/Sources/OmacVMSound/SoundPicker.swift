import AppKit
import ApplicationServices

/// Control Center's Sound list, read and pressed through Accessibility
/// (ADR 0075). macOS has no public API for the AirPlay speakers of the Mac's
/// own sound output (AVRouting's system context and MediaPlayer's routing
/// controller need Apple's entitlements), and Control Center's list differs
/// from what Bonjour finds (a Mac that receives AirPlay is not in it). So the
/// app opens Control Center, moves its window off every display at once
/// (the window server has it on one for 12 to 34 ms, measured on macOS
/// 27.2), opens the Sound module's list, reads or presses a row, and closes
/// it. `took` is how long Control Center was open, in seconds.
///
/// While Control Center is open it has the Mac's keyboard, also off screen:
/// no key reaches the VM. So a session is as short as macOS lets it be, and
/// the app starts one only when the VM asks (SoundGuest).
///
/// Elements are found by role and identifier only: titles, descriptions and
/// the names of custom actions follow the Mac's language.
public final class SoundPicker {
    public enum Failure: Error, Equatable {
        /// OmacVM is not allowed under Accessibility.
        case notTrusted
        /// Control Center is open already (the person uses it): not touched.
        case open
        /// No Control Center, no Sound module or no list this code can read.
        case unsupported(String)
        /// macOS does not offer a device of this name now.
        case noDevice(String)
        /// Control Center closed while the app worked in it (a click elsewhere).
        case interrupted
    }

    public static var trusted: Bool { AXIsProcessTrusted() }

    static let controlCenter = "com.apple.controlcenter"
    /// macOS 26 and later keep the menu bar's extras in this process.
    static let menuBarAgent = "com.apple.MenuBarAgent"
    static let menuExtra = "com.apple.menuextra.controlcenter"
    static let soundToggle = "controlcenter-airplay"
    /// How long macOS may take to connect a speaker before the app closes
    /// Control Center and answers with the list as it is.
    static let connectLimit = 15.0

    public init() {}

    // MARK: Sessions

    /// The list as Control Center shows it now.
    public func read() throws -> (elements: [SoundElement], took: Double) {
        try session { details in try details.settled() }
    }

    /// Presses the device's row as a click in Control Center does, and waits
    /// until macOS is done with it: the row's checkmark changed (macOS takes
    /// the old output's checkmark away first and sets the new one once the
    /// speaker is connected), or macOS gave up and the list is as before.
    public func press(_ name: String) throws -> (elements: [SoundElement], took: Double) {
        try session { details in
            let before = SoundList.rows(try details.settled())
            guard before.contains(where: { $0.name == name }) else { throw Failure.noDevice(name) }
            try details.press(SoundList.rowPrefix + name)
            var moved = false
            return try details.wait(limit: Self.connectLimit) { now in
                let rows = SoundList.rows(now)
                if rows != before { moved = true }
                return SoundList.pressDone(name, before: before, now: rows, moved: moved)
            }
        }
    }

    private func session(_ work: (Details) throws -> [SoundElement]) throws -> (elements: [SoundElement], took: Double) {
        guard Self.trusted else { throw Failure.notTrusted }
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: Self.controlCenter).first else {
            throw Failure.unsupported("Control Center is not running")
        }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        guard AX.windows(app).isEmpty else { throw Failure.open }
        guard let extra = Self.extra(app) else { throw Failure.unsupported("no Control Center in the menu bar") }
        let away = Self.offScreen()
        let start = ProcessInfo.processInfo.systemUptime
        guard AXUIElementPerformAction(extra, kAXPressAction as CFString) == .success else {
            throw Failure.unsupported("Control Center did not open")
        }
        // From here Control Center is open, or opening: it is closed on every way out.
        defer { Self.close(app, extra) }
        guard let window = AX.wait(2, { AX.windows(app).first }) else { throw Failure.unsupported("Control Center did not open") }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, away)
        guard let toggle = AX.wait(2, { AX.find(window, identifier: Self.soundToggle) }) else {
            throw AX.windows(app).isEmpty ? Failure.interrupted : Failure.unsupported("no Sound module in Control Center")
        }
        // The module's list is behind the one custom action of its button
        // ("show details" in English).
        guard let show = AX.actions(toggle).first(where: { $0.hasPrefix("Name:") }),
              AXUIElementPerformAction(toggle, show as CFString) == .success else {
            throw Failure.unsupported("the Sound module has no list")
        }
        let elements = try work(Details(app: app, window: window))
        Self.close(app, extra)
        return (elements, ProcessInfo.processInfo.systemUptime - start)
    }

    /// Control Center's item in the menu bar: its own on macOS 15, the menu
    /// bar agent's from macOS 26.
    private static func extra(_ app: AXUIElement) -> AXUIElement? {
        var bars = [AX.element(app, "AXExtrasMenuBar")]
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgent).first {
            let a = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(a, 2)
            bars.append(AX.element(a, "AXExtrasMenuBar"))
        }
        for case let bar? in bars {
            if let e = AX.find(bar, identifier: menuExtra) { return e }
        }
        return nil
    }

    /// A place outside every display, so nothing of the window shows there.
    /// macOS puts it back at the menu bar at its next opening.
    private static func offScreen() -> AXValue {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let all = ids.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
        var point = CGPoint(x: (all.isNull ? 0 : all.minX) - 4000, y: (all.isNull ? 0 : all.minY) - 4000)
        return AXValueCreate(.cgPoint, &point)!
    }

    /// A press of the menu bar item goes one page back (the list, then the
    /// modules), then closes Control Center.
    private static func close(_ app: AXUIElement, _ extra: AXUIElement) {
        for _ in 0..<4 {
            guard let window = AX.windows(app).first else { return }
            let list = AX.find(window, identifier: SoundList.title) != nil
            AXUIElementPerformAction(extra, kAXPressAction as CFString)
            _ = AX.wait(1.5) { () -> Bool? in
                guard let w = AX.windows(app).first else { return true }
                return (AX.find(w, identifier: SoundList.title) != nil) != list ? true : nil
            }
        }
    }

    /// The open list.
    final class Details {
        let app: AXUIElement, window: AXUIElement
        init(app: AXUIElement, window: AXUIElement) { self.app = app; self.window = window }

        private func scan() throws -> [(SoundElement, AXUIElement)] {
            // A click anywhere closes Control Center: its elements then answer nothing.
            guard !AX.windows(app).isEmpty else { throw Failure.interrupted }
            var out: [(SoundElement, AXUIElement)] = []
            AX.walk(window, 0) { e, depth in
                out.append((SoundElement(depth: depth, role: AX.string(e, kAXRoleAttribute), subrole: AX.string(e, kAXSubroleAttribute),
                                         identifier: AX.string(e, kAXIdentifierAttribute), description: AX.string(e, kAXDescriptionAttribute),
                                         value: AX.string(e, kAXValueAttribute)), e))
            }
            return out
        }

        func read() throws -> [SoundElement] { try scan().map(\.0) }

        /// The list once it stands: two reads in a row agree, with a device in them.
        func settled() throws -> [SoundElement] {
            let end = ProcessInfo.processInfo.systemUptime + 3
            var last: [SoundElement] = []
            while ProcessInfo.processInfo.systemUptime < end {
                let now = try read()
                if !SoundList.rows(now).isEmpty, now == last { return now }
                last = now
                usleep(60_000)
            }
            if SoundList.rows(last).isEmpty { throw Failure.unsupported("the Sound module shows no devices") }
            return last
        }

        func wait(limit: Double, _ done: ([SoundElement]) -> Bool) throws -> [SoundElement] {
            let end = ProcessInfo.processInfo.systemUptime + limit
            var now = try read()
            while !done(now), ProcessInfo.processInfo.systemUptime < end {
                usleep(60_000)
                now = try read()
            }
            return now
        }

        func press(_ identifier: String) throws {
            guard let e = try scan().first(where: { $0.0.identifier == identifier && $0.0.role == SoundList.rowRole })?.1,
                  AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else { throw Failure.interrupted }
        }
    }
}

/// Accessibility's calls, as this file needs them.
enum AX {
    static func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ key: String) -> String {
        switch attr(e, key) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    static func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
        guard let v = attr(e, key), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func windows(_ app: AXUIElement) -> [AXUIElement] { attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return names as? [String] ?? []
    }

    static func walk(_ e: AXUIElement, _ depth: Int, _ visit: (AXUIElement, Int) -> Void) {
        guard depth < 24 else { return }
        visit(e, depth)
        for c in children(e) { walk(c, depth + 1, visit) }
    }

    static func find(_ root: AXUIElement, identifier: String) -> AXUIElement? {
        var hit: AXUIElement?
        walk(root, 0) { e, _ in if hit == nil, string(e, kAXIdentifierAttribute) == identifier { hit = e } }
        return hit
    }

    /// The first answer within `limit` seconds, asked every 2 ms.
    static func wait<T>(_ limit: Double, _ ask: () -> T?) -> T? {
        let end = ProcessInfo.processInfo.systemUptime + limit
        repeat {
            if let v = ask() { return v }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < end
        return nil
    }
}

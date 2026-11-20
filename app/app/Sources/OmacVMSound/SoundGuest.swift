import Foundation

/// The Mac's sound for the VM's audio panel (ADR 0075): GET or POST
/// /omacvm/app/sound on the VM's control port. The app answers it itself, as
/// it does /omacvm/app/extra-brightness: what OmacVM Bridge's /audio does not
/// have, the AirPlay speakers of Control Center's Sound list (SoundPicker)
/// and the output's balance (SoundOutput).
///
///   GET                        {"accessibility", "output", "balance"}
///   POST {"read": true}        the list: + {"devices": [{"name", "selected"}], "ms"}
///   POST {"press": NAME}       presses that device's row, answers the list once macOS is done
///   POST {"balance": 0...1}    0 left, 0.5 centre, 1 right
///
/// "output" is the CoreAudio UID of the Mac's output, as the Bridge's /audio
/// names it (null: none), so the panel knows which output a list's
/// checkmarks were read for. "balance" is {"value", "settable"}, or null
/// when the output has none.
/// "devices" are all outputs macOS lists, the Mac's own too: the panel knows
/// those from the Bridge and shows the others as AirPlay. "ms" is how long
/// Control Center was open for it.
///
/// Only for a VM whose feature bridge is on (NativeControlBridge): the audio
/// panel is that feature's.
///
/// The guest is untrusted: one exact path, a body of exactly one of these
/// keys, a device only by a name the list has right now, and every POST
/// only while this VM's window is the app in front. A read or a press opens
/// Control Center (off screen), which has the Mac's keyboard for that
/// second: a VM in the background must not do that to the one in front.
public enum SoundGuest {
    public static let path = "/omacvm/app/sound"

    public enum Request: Equatable {
        case state
        case read
        case press(String)
        case balance(Double)
    }

    public struct Refusal: Error, Equatable {
        public let status: Int, code: String
        public init(_ status: Int, _ code: String) { self.status = status; self.code = code }
    }

    public static func parse(method: String, body: Data?, front: Bool) -> Result<Request, Refusal> {
        switch method {
        case "GET":
            return body == nil ? .success(.state) : .failure(Refusal(400, "bad-request"))
        case "POST":
            guard let body, let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], o.count == 1,
                  let request = request(o) else { return .failure(Refusal(400, "bad-request")) }
            return front ? .success(request) : .failure(Refusal(409, "not-front"))
        default:
            return .failure(Refusal(405, "method"))
        }
    }

    private static func request(_ o: [String: Any]) -> Request? {
        if let v = o["read"] as? NSNumber, isBool(v), v.boolValue { return .read }
        if let name = o["press"] as? String, (1...255).contains(name.count),
           !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return .press(name) }
        if let v = o["balance"] as? NSNumber, !isBool(v), (0...1).contains(v.doubleValue) { return .balance(v.doubleValue) }
        return nil
    }

    /// A real JSON boolean (0 and 1 are numbers).
    private static func isBool(_ v: NSNumber) -> Bool { CFGetTypeID(v) == CFBooleanGetTypeID() }

    public static func refusal(_ failure: SoundPicker.Failure) -> Refusal {
        switch failure {
        case .notTrusted: return Refusal(403, "accessibility")
        case .open: return Refusal(409, "busy")
        case .unsupported: return Refusal(501, "unsupported")
        case .noDevice: return Refusal(409, "no-device")
        case .interrupted: return Refusal(409, "interrupted")
        }
    }

    public static func error(_ code: String) -> String {
        switch code {
        case "bad-request": return "send {\"read\": true}, {\"press\": NAME} or {\"balance\": 0...1}"
        case "not-front": return "only while this VM's window is in front"
        case "accessibility": return "OmacVM is not allowed under Accessibility on the Mac"
        case "busy": return "Control Center is open on the Mac"
        case "unsupported": return "this macOS has no Sound list in Control Center that OmacVM can read"
        case "no-device": return "macOS does not list that device now"
        case "interrupted": return "Control Center closed before macOS was done"
        case "no-balance": return "this output has no balance that can be set"
        default: return "GET or POST"
        }
    }

    public static func state(accessibility: Bool, output: String?, balance: (value: Double, settable: Bool)?) -> [String: Any] {
        ["accessibility": accessibility, "output": output ?? NSNull(),
         "balance": balance.map { ["value": round3($0.value), "settable": $0.settable] as [String: Any] } ?? NSNull()]
    }

    public static func devices(_ rows: [SoundRow]) -> [[String: Any]] {
        rows.map { ["name": $0.name, "selected": $0.selected] }
    }

    /// 0.563, not 0.56299999999999994, in the JSON.
    static func round3(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", v)) }
}

/// Answers SoundGuest's requests on this Mac. One Control Center session at
/// a time: a second request waits for the first.
public final class SoundService: @unchecked Sendable {
    private let lock = NSLock()
    private let picker = SoundPicker()
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void) { self.log = log }

    public func answer(method: String, body: Data?, front: Bool) -> (Int, [String: Any]) {
        func refuse(_ r: SoundGuest.Refusal) -> (Int, [String: Any]) { (r.status, ["code": r.code, "error": SoundGuest.error(r.code)]) }
        func state() -> [String: Any] { SoundGuest.state(accessibility: SoundPicker.trusted, output: SoundOutput.uid, balance: SoundOutput.balance) }
        switch SoundGuest.parse(method: method, body: body, front: front) {
        case .failure(let r):
            return refuse(r)
        case .success(.state):
            return (200, state())
        case .success(.balance(let value)):
            guard SoundOutput.setBalance(value) else { return refuse(SoundGuest.Refusal(409, "no-balance")) }
            return (200, state())
        case .success(.read):
            return list("read the Sound list") { try picker.read() }
        case .success(.press(let name)):
            return list("pressed \(name)") { try picker.press(name) }
        }

        func list(_ what: String, _ work: () throws -> (elements: [SoundElement], took: Double)) -> (Int, [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            do {
                let (elements, took) = try work()
                let ms = Int((took * 1000).rounded())
                var a = state()
                a["devices"] = SoundGuest.devices(SoundList.rows(elements))
                a["ms"] = ms
                log("\(what): Control Center open \(ms) ms")
                return (200, a)
            } catch let failure as SoundPicker.Failure {
                if case .unsupported(let why) = failure { log("\(what): \(why)") }
                return refuse(SoundGuest.refusal(failure))
            } catch {
                return refuse(SoundGuest.Refusal(501, "unsupported"))
            }
        }
    }

    /// The list's elements as Accessibility gives them, one per line, for
    /// `OmacVM --sound tree`: what to send along when a macOS shows a list
    /// this code cannot read.
    public func tree() -> String {
        lock.lock(); defer { lock.unlock() }
        do {
            return try picker.read().elements.map { e in
                String(repeating: "  ", count: e.depth) + [e.role, e.subrole, e.identifier, e.description, e.value].joined(separator: "|")
            }.joined(separator: "\n")
        } catch {
            return "no list: \(error)"
        }
    }
}

// The Mac's sound for the VM's audio panel (OmacVMSound), without Control
// Center:
//   cd app/app && swift run sound-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMSound

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// Control Center's Sound list on a Mac mini with a Studio Display XDR and a
// HomePod called Living Room, as `OmacVM --sound tree` printed it (macOS
// 27.2.1, 2026-11-20). The titles follow the Mac's language, the identifiers
// do not.
func list(display: String, livingRoom: String, mini: String = "0") -> [SoundElement] {
    [SoundElement(depth: 0, role: "AXWindow", subrole: "AXSystemDialog"),
     SoundElement(depth: 1, role: "AXGroup", subrole: "AXHostingView"),
     SoundElement(depth: 2, role: "AXStaticText", identifier: "controlcenter-volume", value: "Sound"),
     SoundElement(depth: 2, role: "AXButton", description: "Volume Lower"),
     SoundElement(depth: 2, role: "AXSlider", identifier: "controlcenter-volume-slider", description: "sound volume", value: "0.3038005828857422"),
     SoundElement(depth: 3, role: "AXValueIndicator"),
     SoundElement(depth: 2, role: "AXButton", description: "Volume Higher"),
     SoundElement(depth: 2, role: "AXScrollArea"),
     SoundElement(depth: 3, role: "AXHeading", description: "Output"),
     SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-Mac mini Speakers", description: "Mac mini Speakers", value: mini),
     SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-Studio Display XDR Speakers", description: "Studio Display XDR Speakers", value: display),
     SoundElement(depth: 3, role: "AXCheckBox", subrole: "AXToggle", identifier: "sound-device-Living Room", description: "Living Room", value: livingRoom),
     SoundElement(depth: 2, role: "AXButton", description: "Sound Settings…")]
}

let onDisplay = SoundList.rows(list(display: "1", livingRoom: "0"))
expect(onDisplay == [SoundRow(name: "Mac mini Speakers", selected: false), SoundRow(name: "Studio Display XDR Speakers", selected: true),
                     SoundRow(name: "Living Room", selected: false)],
       "the list on the display's speakers: three devices in Control Center's order, the display's with the checkmark")
expect(SoundList.rows([SoundElement(depth: 0, role: "AXCheckBox", identifier: "controlcenter-airplay", value: "0"),
                       SoundElement(depth: 0, role: "AXCheckBox", identifier: "sound-device-", value: "1"),
                       SoundElement(depth: 0, role: "AXButton", identifier: "sound-device-Living Room")]).isEmpty,
       "the Sound module's own button, a row without a name and a button are no devices")

// A press of Living Room on the HomePod, as Control Center's list moved
// (2026-11-20): the display's checkmark went after 16 ms, the HomePod's came
// after 420 ms, when it was connected.
let connecting = SoundList.rows(list(display: "0", livingRoom: "0"))
let onHomePod = SoundList.rows(list(display: "0", livingRoom: "1"))
expect(!SoundList.pressDone("Living Room", before: onDisplay, now: onDisplay, moved: false), "right after the press: not done")
expect(!SoundList.pressDone("Living Room", before: onDisplay, now: connecting, moved: true), "while macOS connects (no checkmark anywhere): not done")
expect(SoundList.pressDone("Living Room", before: onDisplay, now: onHomePod, moved: true), "the HomePod has the checkmark: done")
expect(SoundList.pressDone("Living Room", before: onDisplay, now: onDisplay, moved: true),
       "the speaker did not connect and the display has its checkmark again: done")
expect(SoundList.pressDone("Living Room", before: onHomePod, now: connecting, moved: true), "a press of the playing HomePod takes its checkmark: done")
expect(!SoundList.pressDone("Living Room", before: onDisplay, now: SoundList.rows(list(display: "0", livingRoom: "0")).dropLast(), moved: true),
       "the row is gone for a moment: not done")

// The route's rules.
func body(_ s: String) -> Data { Data(s.utf8) }
func parse(_ method: String, _ b: String? = nil, front: Bool = true) -> Result<SoundGuest.Request, SoundGuest.Refusal> {
    SoundGuest.parse(method: method, body: b.map(body), front: front)
}
expect(parse("GET") == .success(.state), "GET: the state")
expect(parse("GET", front: false) == .success(.state), "GET: also for a VM in the background")
expect(parse("GET", "{}") == .failure(.init(400, "bad-request")), "GET with a body: refused")
expect(parse("POST", #"{"read": true}"#) == .success(.read), "POST read")
expect(parse("POST", #"{"read": false}"#) == .failure(.init(400, "bad-request")), "read: false is nothing to do")
expect(parse("POST", #"{"read": 1}"#) == .failure(.init(400, "bad-request")), "read: 1 is a number, not true")
expect(parse("POST", #"{"press": "Living Room"}"#) == .success(.press("Living Room")), "POST press with a device's name")
expect(parse("POST", #"{"press": ""}"#) == .failure(.init(400, "bad-request")), "press: no name")
expect(parse("POST", #"{"press": "a\nb"}"#) == .failure(.init(400, "bad-request")), "press: a name with a line break")
expect(parse("POST", "{\"press\": \"\(String(repeating: "a", count: 256))\"}") == .failure(.init(400, "bad-request")), "press: a name of 256 characters")
expect(parse("POST", #"{"balance": 0.25}"#) == .success(.balance(0.25)), "POST balance")
expect(parse("POST", #"{"balance": 1.5}"#) == .failure(.init(400, "bad-request")), "balance: outside 0...1")
expect(parse("POST", #"{"balance": true}"#) == .failure(.init(400, "bad-request")), "balance: true is no number")
expect(parse("POST", #"{"read": true, "press": "Living Room"}"#) == .failure(.init(400, "bad-request")), "two keys: refused")
expect(parse("POST", #"["read"]"#) == .failure(.init(400, "bad-request")), "a body that is no object: refused")
expect(parse("POST") == .failure(.init(400, "bad-request")), "POST without a body: refused")
expect(parse("POST", #"{"press": "Living Room"}"#, front: false) == .failure(.init(409, "not-front")),
       "a VM in the background cannot press")
expect(parse("POST", #"{"balance": 0.5}"#, front: false) == .failure(.init(409, "not-front")), "nor set the balance")
expect(parse("POST", #"{"nonsense": 1}"#, front: false) == .failure(.init(400, "bad-request")), "a bad request is a bad request, in front or not")
expect(parse("PUT") == .failure(.init(405, "method")), "another method: refused")

// The answers.
let none = SoundGuest.state(accessibility: false, output: nil, balance: nil)
expect(none["accessibility"] as? Bool == false && none["output"] is NSNull && none["balance"] is NSNull,
       "no Accessibility, no output, no balance: false, null and null")
let some = SoundGuest.state(accessibility: true, output: "BuiltInSpeakerDevice", balance: (value: 0.5629999, settable: true))
expect(some["output"] as? String == "BuiltInSpeakerDevice", "the output's CoreAudio UID")
expect((some["balance"] as? [String: Any])?["value"] as? NSNumber == NSDecimalNumber(string: "0.563")
       && (some["balance"] as? [String: Any])?["settable"] as? Bool == true, "the balance, rounded to three places")
expect(String(decoding: try! JSONSerialization.data(withJSONObject: SoundGuest.devices(onHomePod.suffix(1)), options: [.sortedKeys]), as: UTF8.self)
       == #"[{"name":"Living Room","selected":true}]"#, "a device in the answer: its name and its checkmark")
for (failure, code) in [(SoundPicker.Failure.notTrusted, "accessibility"), (.open, "busy"), (.unsupported("why"), "unsupported"),
                        (.noDevice("Kitchen"), "no-device"), (.interrupted, "interrupted")] {
    let r = SoundGuest.refusal(failure)
    expect(r.code == code && SoundGuest.error(code) != SoundGuest.error("method"), "\(failure): \(r.status) \(code), with a text of its own")
}
for code in ["bad-request", "not-front", "no-balance"] {
    expect(SoundGuest.error(code) != SoundGuest.error("method"), "\(code): a text of its own")
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")

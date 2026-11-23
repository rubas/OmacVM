#!/bin/bash
# The audio panel's output list (src/bridge/plugins/omacvm.audio/Model.js):
# which of the outputs macOS lists are AirPlay speakers, which row has the
# checkmark, which row has the modes of headphones, and where the cursor
# stops. On the payloads of a Mac mini with a Studio Display XDR, a HomePod
# called Living Room and AirPods Pro (2026-11-20).
#   src/tests/audio-panel-model.sh
set -euo pipefail
cd "$(dirname "$0")/../bridge/plugins/omacvm.audio"
node - <<'JS'
const M = require("./Model.js")
let failed = 0
function expect(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what); if (!ok) failed++ }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

const display = { uid: "AppleUSBAudioEngine:display:10,11", name: "Studio Display XDR Speakers", transport: "usb", has_output: true, has_input: false, default_output: true, default_input: false }
const mic = { uid: "AppleUSBAudioEngine:display:8,9", name: "Studio Display XDR Microphone", transport: "usb", has_output: false, has_input: true, default_output: false, default_input: true }
const mini = { uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", transport: "built-in", has_output: true, has_input: false, default_output: false, default_input: false }
const airplayDevice = { uid: "77331758-Audio", name: "AirPlay", transport: "airplay", has_output: true, has_input: false, default_output: true, default_input: false }
const onDisplay = { output: display, devices: [display, mic, mini] }
const onAirplay = { output: airplayDevice, devices: [airplayDevice, Object.assign({}, display, { default_output: false }), mic, mini] }
const bluetooth = { devices: [{ name: "Dominic’s Apple Watch", paired: true, connected: false }, { name: "Headset", paired: true, connected: false }] }
const listed = (selected, output) => ({ accessibility: true, devicesOutput: output, devices: [
  { name: "Mac mini Speakers", selected: false }, { name: "Studio Display XDR Speakers", selected: selected === "display" },
  { name: "Living Room", selected: selected === "living" }] })
const names = rows => rows.map(r => r.name + (r.active ? "*" : ""))

let l = M.outputLists(onDisplay, bluetooth, null)
expect(same(names(l.outputs), ["Studio Display XDR Speakers*", "Mac mini Speakers"]) && l.airplay.length === 0,
  "an app without the list (an older one): CoreAudio's outputs alone, as before")
expect(same(names(M.outputLists(onAirplay, bluetooth, null).outputs), ["AirPlay*", "Studio Display XDR Speakers", "Mac mini Speakers"]),
  "on AirPlay with such an app: CoreAudio's AirPlay row stays, as before")

l = M.outputLists(onAirplay, bluetooth, { accessibility: false, devices: null, devicesOutput: "" })
expect(same(names(l.outputs), ["AirPlay*", "Studio Display XDR Speakers", "Mac mini Speakers"]) && l.airplay.length === 1 && l.airplay[0].allow === true && !l.airplay[0].picker,
  "macOS does not let the app read its list: one row that opens the Mac's settings, and CoreAudio's AirPlay row")

l = M.outputLists(onDisplay, bluetooth, listed("display", display.uid))
expect(same(names(l.outputs), ["Studio Display XDR Speakers*", "Mac mini Speakers"]), "the Mac's own outputs are listed once, from CoreAudio")
expect(same(names(l.airplay), ["Living Room"]) && l.airplay[0].picker && l.airplay[0].transport === "airplay",
  "the HomePod, which CoreAudio does not know, is an AirPlay row, switched through macOS's list")

l = M.outputLists(onAirplay, bluetooth, listed("living", airplayDevice.uid))
expect(same(names(l.outputs), ["Studio Display XDR Speakers", "Mac mini Speakers"]) && same(names(l.airplay), ["Living Room*"]),
  "on AirPlay: the HomePod's own row has the checkmark, and CoreAudio's AirPlay device has no row")

l = M.outputLists(onDisplay, bluetooth, listed("living", airplayDevice.uid))
expect(same(names(l.airplay), ["Living Room"]), "back on the display's speakers: no AirPlay checkmark, without asking the Mac")

const stale = listed("living", "another-airplay-session-Audio")
l = M.outputLists(onAirplay, bluetooth, stale)
expect(same(names(l.airplay), ["Living Room"]) && same(names(l.outputs), ["AirPlay*", "Studio Display XDR Speakers", "Mac mini Speakers"]),
  "on AirPlay again since the list was read: nobody knows which speaker plays, so CoreAudio's AirPlay row has the checkmark")
l = M.outputLists(onAirplay, bluetooth, Object.assign({ reading: true }, stale))
expect(same(names(l.airplay), ["Living Room"]) && same(names(l.outputs), ["Studio Display XDR Speakers", "Mac mini Speakers"]),
  "while the list is being read: no AirPlay row that the speaker's own row would replace a second later")

const withHeadset = listed("display", display.uid)
withHeadset.devices.push({ name: "Headset", selected: false })
l = M.outputLists(onDisplay, bluetooth, withHeadset)
expect(same(names(l.outputs), ["Studio Display XDR Speakers*", "Mac mini Speakers", "Headset"]) && l.outputs[2].picker && same(names(l.airplay), ["Living Room"]),
  "a paired headset that is not connected is an output, not an AirPlay speaker")
// AirPods Pro as the output (2026-11-20): CoreAudio and macOS's list name them alike, and the list has their modes.
const pods = { uid: "48-A9-1C-63-0F-2A:output", name: "AirPods Pro - Find My", transport: "bluetooth", has_output: true, has_input: false, default_output: true, default_input: false }
const onPods = { output: pods, devices: [pods, Object.assign({}, display, { default_output: false }), mic, mini] }
const option = (title, selected, enabled) => ({ title: title, selected: selected, enabled: enabled !== false })
const modes = [{ title: "Listening Mode", options: [option("Transparency", true), option("Adaptive", false), option("Noise Cancellation", false)] },
  { title: "Spatial Audio", options: [option("Not Available", true, false)] },
  { title: "Conversation Awareness", options: [option("Off", true), option("On", false)] }]
const podsListed = (output, selected) => ({ accessibility: true, devicesOutput: output, devices: [
  { name: "Mac mini Speakers", selected: false }, { name: "Studio Display XDR Speakers", selected: !selected },
  { name: "AirPods Pro - Find My", selected: selected, modes: modes }, { name: "Living Room", selected: false }] })
const groups = rows => rows.map(r => r.name + ":" + (r.modes || []).map(g => g.title).join("/"))

l = M.outputLists(onPods, bluetooth, podsListed(pods.uid, true))
expect(same(groups(l.outputs), ["AirPods Pro - Find My:Listening Mode/Conversation Awareness", "Studio Display XDR Speakers:", "Mac mini Speakers:"])
  && same(names(l.airplay), ["Living Room"]),
  "the AirPods play: their row, once, has macOS's groups of modes, and no other row has any; Spatial Audio, whose one option macOS does not offer, is not shown")
const noneOffered = podsListed(pods.uid, true)
noneOffered.devices[2] = Object.assign({}, noneOffered.devices[2], { modes: [modes[1]] })
expect(!M.outputLists(onPods, bluetooth, noneOffered).outputs[0].modes, "AirPods with no option offered at all: no modes under their row")
expect(same(groups(M.outputLists(onPods, bluetooth, podsListed("AppleUSBAudioEngine:display:10,11", false)).outputs)[0], "AirPods Pro - Find My:"),
  "a list read for another output: no modes, as nobody knows them for the AirPods now")
const podsIdle = Object.assign({}, pods, { default_output: false })
l = M.outputLists({ output: display, devices: [podsIdle, display, mic, mini] }, bluetooth, podsListed(display.uid, false))
expect(same(groups(l.outputs), ["AirPods Pro - Find My:", "Studio Display XDR Speakers:", "Mac mini Speakers:"]),
  "the display plays and the AirPods are connected: no modes under any row")

l = M.outputLists(onPods, bluetooth, podsListed(pods.uid, true))
const stops = M.outputStops(l.outputs, l.airplay)
expect(same(stops.map(s => s.row.name + (s.group ? " > " + s.group.title : "")),
  ["AirPods Pro - Find My", "AirPods Pro - Find My > Listening Mode", "AirPods Pro - Find My > Conversation Awareness",
   "Studio Display XDR Speakers", "Mac mini Speakers", "Living Room"]),
  "the cursor: the AirPods' row, a stop per group under it, then the other rows")
expect(same([l.outputs[0].stop, l.outputs[0].modes.map(g => g.stop), l.airplay[0].stop], [0, [1, 2], 5]),
  "each row and group knows its stop")
const listening = l.outputs[0].modes[0]
expect(M.optionCursor(listening, -1, 0) === 0 && M.optionCursor(listening, 0, 1) === 1 && M.optionCursor(listening, 2, 1) === 2 && M.optionCursor(listening, 0, -1) === 0,
  "on Listening Mode the cursor lands on Transparency, which macOS selected, and h/l walk the options and stop at the ends")
const someOff = { title: "Spatial Audio", options: [option("Off", false), option("Fixed", true, false), option("Head Tracked", false)] }
expect(M.optionCursor(someOff, -1, 0) === 0 && M.optionCursor(someOff, 0, 1) === 2,
  "an option macOS does not offer is never under the cursor, also when it is selected")
// The panel's reads of macOS's Sound list. Each event below calls Panel.qml's
// askForList as the panel's handlers do (an opening, the Bridge's report of
// the output, the app's answer to a read or a press); it reads only while
// the app is free. On the AirPods Pro above, whose modes macOS keeps
// closed until a read opens them.
function panel(output) {
  const p = { output: output, asked: null, job: "", reads: [] }
  // Sound's read and press start only while the app is free.
  const start = job => { if (p.job) return false; p.job = job; return true }
  p.ask = () => {
    const uid = M.listRead(p.asked, p.output)
    if (uid !== null && start("read")) { p.asked = uid; p.reads.push(p.output ? p.output.name : "") }
  }
  p.open = () => { p.asked = null; p.ask() }
  p.bridge = o => { p.output = o; p.ask() }
  p.press = () => { start("press") }
  p.free = failed => {
    if (p.job === "press" && !failed && p.asked !== null) p.asked = ""
    p.job = ""
    p.ask()
  }
  return p
}
const reads = p => p.reads.join(", ")
let p = panel(display)
p.open(); p.free(); p.press(); p.bridge(pods); p.free()
expect(reads(p) === "Studio Display XDR Speakers, AirPods Pro - Find My",
  "a click on the AirPods: the Bridge reports them before the press answers, and the panel reads the list once more for their modes")
p = panel(display)
p.open(); p.free(); p.press(); p.free(); p.bridge(pods)
expect(reads(p) === "Studio Display XDR Speakers, AirPods Pro - Find My",
  "the Bridge reports the AirPods after the press answered: the same read for their modes")
p = panel(display)
p.open(); p.bridge(pods); p.free()
expect(reads(p) === "Studio Display XDR Speakers, AirPods Pro - Find My",
  "the AirPods begin to play while the opening's read is on its way: one more read once it answered")
p.free(); p.bridge(display); p.bridge(pods); p.free()
expect(p.reads.length === 2, "one read per output: back on the display, then on the AirPods again, the list still has their modes")
p.open(); p.free()
expect(p.reads.length === 3, "the next opening reads once")
p = panel(pods)
p.open(); p.free(); p.press(); p.bridge(airplayDevice); p.free(); p.bridge(pods); p.free()
expect(reads(p) === "AirPods Pro - Find My, AirPods Pro - Find My",
  "from the AirPods to an AirPlay speaker and back through their own row: the speaker's list lacks their modes, so one more read")
p = panel(pods)
p.open(); p.free(); p.press(); p.free(true)
expect(reads(p) === "AirPods Pro - Find My", "a press that fails while the AirPods play: no read, and the failure's line stays")
p = panel(display)
p.open(); p.bridge(pods); p.open(); p.free()
expect(reads(p) === "Studio Display XDR Speakers, AirPods Pro - Find My",
  "opened again while the last opening's read is on its way: a read of its own once that one answered")
p = panel(display)
p.open(); p.free(); p.press(); p.open(); p.free()
expect(reads(p) === "Studio Display XDR Speakers, Studio Display XDR Speakers",
  "opened again while the last opening's press is on its way: the press's list leaves this opening's own read to come")
p = panel(display)
p.open(); p.free(); p.bridge(display); p.press(); p.free()
expect(reads(p) === "Studio Display XDR Speakers", "the display plays: one read per opening, also after a press of an AirPlay speaker")
process.exit(failed ? 1 : 0)
JS
echo "audio-panel-model: all passed"

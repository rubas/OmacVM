#!/bin/bash
# The audio panel's output list (src/bridge/plugins/omacvm.audio/Model.js):
# which of the outputs macOS lists are AirPlay speakers, which row has the
# checkmark, which row has the modes of headphones, where the cursor stops,
# and when the panel reads macOS's Sound list (also on random orders of
# events; OMACVM_SEED=N replays a run). On the payloads of a Mac mini with a
# Studio Display XDR, a HomePod called Living Room and AirPods Pro
# (2026-11-20).
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
// The promise of the panel's reads, on random orders of events: once the
// app is free, the list has the modes of the Bluetooth output that plays;
// each opening reads once; and between two reads there is a reason for the
// second (an opening, a press of a row that answered with a list, the
// Bridge's report of a Bluetooth output), so no loop
// takes the Mac's keyboard over and over. The world around Model.listRead,
// as the panel's handlers call it: openings and closings; the state request
// of an opening before the app is known; the Mac's output, which changes by
// itself, by a click on a CoreAudio row (through the Bridge) or by a press of
// a row of macOS's list (AirPlay, a headset that is not connected), which may
// fail to connect; the Bridge's report of the output as it is then, late,
// skipping changes in between, or again with the same output; the app's
// request, which looks at Control Center at some moment and answers later,
// or fails (a mode whose device no longer plays fails); and Control Center's
// disclosures, which a read or a mode opens and which stay as a read or the
// person left them. Assumed: nobody closes a disclosure on the Mac while the
// panel is open.
// Accepted, as the panel then shows no modes, never wrong ones, and the next
// opening reads again: a failed read is not tried again for its output in
// that opening, because a refusal such as "busy" (the person has Control
// Center open) would come back at once, over and over. And a list that
// belongs to another output, because the Mac's output changed while the app
// looked at Control Center and changed back to the output that the panel
// noted for its last read before the Bridge reported the change.
// OMACVM_SEED=N replays a run.
const headset = { uid: "4C-87-5D-10-22-AB:output", name: "Headset", transport: "bluetooth" }
const outputs = [display, mini, pods, headset, airplayDevice]
const bt = o => !!o && o.transport === "bluetooth"
function panelWorld(seed) {
  let s = seed >>> 0
  const rnd = () => { s = (s + 0x6D2B79F5) >>> 0; let t = s; t = Math.imul(t ^ t >>> 15, t | 1); t ^= t + Math.imul(t ^ t >>> 7, t | 61); return ((t ^ t >>> 14) >>> 0) / 4294967296 }
  const pick = a => a[Math.floor(rnd() * a.length)]
  const w = { mac: pick(outputs), open: false, opening: 0, openingRead: false, ready: false, stateJob: false, job: null, asked: null,
    list: null, readFailed: false, disclosure: {}, reason: false, broke: "" }
  w.output = w.mac
  for (const o of outputs) w.disclosure[o.uid] = bt(o) && rnd() < 0.5
  // Panel.qml's askForList; Sound.qml's run takes one request at a time.
  const ask = () => {
    if (!w.open || !w.ready) return
    const uid = M.listRead(w.asked, w.output)
    if (uid === null || w.job) return
    if (!w.reason) w.broke = "a read without a reason"
    w.reason = false
    w.job = { kind: "read", for: uid, opening: w.opening }
    w.asked = uid; w.readFailed = false; w.openingRead = true
  }
  const look = j => { if (!j.seen) { j.seen = w.mac; if (j.kind === "mode" && j.seen !== j.device) j.refused = true } }
  const events = {
    open: () => {
      if (w.open) return
      w.open = true; w.opening++; w.openingRead = false; w.reason = true; w.asked = null; w.readFailed = false
      if (w.ready) ask(); else w.stateJob = true
    },
    close: () => { w.open = false },
    stateAnswer: () => { if (w.stateJob) { w.stateJob = false; w.ready = true; ask() } },
    macSwitch: () => { w.mac = pick(outputs) },
    bridge: () => {
      if (w.open && w.mac !== w.output && bt(w.mac)) w.reason = true
      w.output = w.mac
      ask()
    },
    rowClick: () => { const o = pick([display, mini, pods]); if (w.open && o !== w.output) w.mac = o },
    press: () => {
      if (!w.open || !w.ready || w.job) return
      w.job = { kind: "press", target: pick([headset, airplayDevice]) }
    },
    mode: () => {
      if (w.open && !w.job && bt(w.output) && w.list && w.list.of === w.output && w.list.modes) w.job = { kind: "mode", device: w.output }
    },
    look: () => { if (w.job && w.job.kind !== "press") look(w.job) },
    connect: () => { if (w.job && w.job.kind === "press") w.mac = w.job.target },
    answer: () => {
      const j = w.job
      if (!j) return
      if (j.kind !== "press") look(j)
      if (j.refused || rnd() < 0.15) {
        if (j.kind === "read" && j.opening === w.opening && j.for === w.asked) w.readFailed = true
        w.stateJob = true
      } else {
        if (j.kind === "press" && rnd() < 0.8) w.mac = j.target
        const of = j.kind === "read" ? j.seen : w.mac
        if (j.kind === "read" && bt(of)) w.disclosure[of.uid] = true
        w.list = { of: of, modes: w.disclosure[of.uid] }
        // Panel.qml's onAnswered: a press's list may lack the modes.
        if (j.kind === "press") { if (w.asked !== null) w.asked = ""; w.reason = true }
      }
      w.job = null
      ask()
    },
  }
  const names = Object.keys(events)
  return { w: w, step: () => { const name = pick(names); events[name](); return name } }
}
function panelRun(seed, steps) {
  const { w, step } = panelWorld(seed)
  const trace = []
  for (let i = 0; i < steps && !w.broke; i++) {
    trace.push(step())
    const o = w.output
    const settled = w.open && w.ready && !w.job && o === w.mac && bt(o)
    const hasModes = !!w.list && w.list.of === o && w.list.modes
    const failed = w.readFailed && w.asked === o.uid
    const otherList = w.asked === o.uid && !!w.list && w.list.of !== o
    if (settled && !hasModes && !failed && !otherList) w.broke = "no modes for " + o.name
    if (w.open && w.ready && !w.job && !w.openingRead) w.broke = "an opening without its read"
  }
  return w.broke ? "seed " + seed + ": " + w.broke + " after " + trace.join(" ") : ""
}
const seedText = process.env.OMACVM_SEED
if (seedText !== undefined && !/^[0-9]+$/.test(seedText)) throw new Error("OMACVM_SEED must be a number: " + seedText)
const seed0 = seedText !== undefined ? Number(seedText) : Math.floor(Math.random() * 4294967296)
let broken = ""
for (let r = 0; r < 20000 && !broken; r++) broken = panelRun(seed0 + r, 60)
expect(!broken, "on 20000 random orders of 60 events (seeds " + seed0 + "+): a read in each opening, the modes of the Bluetooth output that plays once the app is free, and a reason for each read" + (broken ? "; broke at " + broken : ""))
process.exit(failed ? 1 : 0)
JS
echo "audio-panel-model: all passed"

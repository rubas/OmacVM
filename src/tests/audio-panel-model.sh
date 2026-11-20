#!/bin/bash
# The audio panel's output list (src/bridge/plugins/omacvm.audio/Model.js):
# which of the outputs macOS lists are AirPlay speakers, and which row has the
# checkmark. On the payloads of a Mac mini with a Studio
# Display XDR and a HomePod called Living Room (2026-11-20).
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
process.exit(failed ? 1 : 0)
JS
echo "audio-panel-model: all passed"

#!/bin/bash
# The audio panel's lists (src/bridge/plugins/omacvm.audio/Model.js): which of
# the outputs macOS lists are AirPlay speakers, which play, and when the panel
# has to ask the Mac again. On the payloads of a Mac mini with a Studio
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
expect(same(names(l.outputs), ["Studio Display XDR Speakers*", "Mac mini Speakers"]) && l.airplay.length === 0 && l.airplayKnown,
  "before macOS's list is read: CoreAudio's outputs alone, no AirPlay row")
expect(same(names(M.outputLists(onAirplay, bluetooth, null).outputs), ["AirPlay*", "Studio Display XDR Speakers", "Mac mini Speakers"]),
  "on AirPlay with an app that has no list (an older one, no Accessibility): CoreAudio's AirPlay row stays, as before")

l = M.outputLists(onDisplay, bluetooth, listed("display", display.uid))
expect(same(names(l.outputs), ["Studio Display XDR Speakers*", "Mac mini Speakers"]), "the Mac's own outputs are listed once, from CoreAudio")
expect(same(names(l.airplay), ["Living Room"]) && l.airplay[0].picker && l.airplay[0].transport === "airplay",
  "the HomePod, which CoreAudio does not know, is an AirPlay row, switched through macOS's list")

l = M.outputLists(onAirplay, bluetooth, listed("living", airplayDevice.uid))
expect(same(names(l.outputs), ["Studio Display XDR Speakers", "Mac mini Speakers"]), "on AirPlay: the HomePod's row stands for CoreAudio's AirPlay device")
expect(same(names(l.airplay), ["Living Room*"]) && l.airplayKnown, "on AirPlay: the HomePod has the checkmark")

l = M.outputLists(onDisplay, bluetooth, listed("living", airplayDevice.uid))
expect(same(names(l.airplay), ["Living Room"]) && l.airplayKnown, "back on the display's speakers: no AirPlay checkmark, without asking the Mac")

l = M.outputLists(onAirplay, bluetooth, listed("living", "another-airplay-session-Audio"))
expect(same(names(l.airplay), ["Living Room"]) && !l.airplayKnown && same(names(l.outputs), ["AirPlay*", "Studio Display XDR Speakers", "Mac mini Speakers"]),
  "on AirPlay again since the list was read: no speaker's checkmark, CoreAudio's AirPlay row, and the panel has to ask which speakers play")
expect(!M.outputLists(onAirplay, bluetooth, null).airplayKnown, "on AirPlay with no list yet: the panel has to ask")

const withHeadset = listed("display", display.uid)
withHeadset.devices.push({ name: "Headset", selected: false })
l = M.outputLists(onDisplay, bluetooth, withHeadset)
expect(same(names(l.outputs), ["Studio Display XDR Speakers*", "Mac mini Speakers", "Headset"]) && l.outputs[2].picker && same(names(l.airplay), ["Living Room"]),
  "a paired headset that is not connected is an output, not an AirPlay speaker")

expect(M.balanceLabel(0.5) === "CENTER" && M.balanceLabel(0.4) === "LEFT 20%" && M.balanceLabel(1) === "RIGHT 100%" && M.balanceLabel(0.501) === "CENTER",
  "the balance's label: centre, or how far left or right")
process.exit(failed ? 1 : 0)
JS
echo "audio-panel-model: all passed"

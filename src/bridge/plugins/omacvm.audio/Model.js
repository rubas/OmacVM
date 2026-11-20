// Derived from Omarchy's omarchy.audio widget (MIT, see LICENSE). The
// helpers below map omacvm-bridge audio payloads (the Mac's CoreAudio devices)
// onto the native widget's labels and glyphs.

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0) return "Silenced"
  if (p >= 100) return "Concert hall"
  if (p >= 85) return "Party mode"
  if (p >= 70) return "Cranked up"
  if (p >= 50) return "Steady groove"
  if (p >= 30) return "Easy listening"
  if (p >= 15) return "Murmur"
  return "Whisper"
}

function deviceBlob(device) {
  if (!device) return ""
  return String([device.name, device.transport, device.uid].join(" ")).toLowerCase()
}

function isHeadphones(device) {
  var blob = deviceBlob(device)
  return blob.indexOf("headphone") !== -1
    || blob.indexOf("headset") !== -1
    || blob.indexOf("earbud") !== -1
    || blob.indexOf("earphone") !== -1
    || blob.indexOf("airpod") !== -1
    || blob.indexOf("beats") !== -1
}

function sinkGlyph(device) {
  if (!device) return "󰓃"
  if (device.transport === "airplay") return "󰀟"
  if (isHeadphones(device)) return "󰋋"
  var blob = deviceBlob(device)
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("hdmi") !== -1 || blob.indexOf("displayport") !== -1 || blob.indexOf("display") !== -1 || blob.indexOf("airplay") !== -1) return "󰍹"
  return "󰓃"
}

function sourceGlyph(device) {
  if (!device) return "󰍬"
  var blob = deviceBlob(device)
  if (blob.indexOf("headset") !== -1 || isHeadphones(device)) return "󰋋"
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return "󰄀"
  return "󰍬"
}

function deviceLabel(device) {
  if (!device) return "Unknown"
  return String(device.name || device.uid || "Unknown")
}

// Primitives only: rows become Repeater model data.
function deviceRows(audio, wantOutput) {
  var devices = audio && Array.isArray(audio.devices) ? audio.devices : []
  var rows = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (!d) continue
    if (wantOutput ? !d.has_output : !d.has_input) continue
    rows.push({
      uid: String(d.uid || ""),
      name: deviceLabel(d),
      transport: String(d.transport || ""),
      active: wantOutput ? !!d.default_output : !!d.default_input
    })
  }
  return rows
}

// The outputs for the panel's lists, from three sources: CoreAudio's devices
// (audio, omacvm-bridge), the Mac's paired Bluetooth devices (bluetooth,
// omacvm-bridge) and what macOS's own Sound list offers (sound, `omacvm
// sound`). CoreAudio knows a device only while it is connected, so macOS
// lists more: an AirPlay speaker, and a paired headset that is not connected.
// Those are switched through macOS's list (picker: true), the rest by their
// CoreAudio uid.
//   outputs  CoreAudio's outputs, then the headsets macOS offers
//   airplay  every other device macOS lists: AirPlay speakers and TVs
// While AirPlay plays, CoreAudio has one device for it, whatever the
// speakers: it is left out, the speakers' rows stand for it. Their
// checkmarks are the ones macOS's list had when it was read (sound.output is
// the default output's uid then): with another output since, on AirPlay
// again, nobody knows which speakers play (airplayKnown false).
function outputLists(audio, bluetooth, sound) {
  var outputs = []
  var known = {}
  var all = deviceRows(audio, true)
  for (var i = 0; i < all.length; i++) {
    known[all[i].name] = true
    if (all[i].transport !== "airplay") outputs.push(all[i])
  }
  var paired = {}
  var bt = bluetooth && Array.isArray(bluetooth.devices) ? bluetooth.devices : []
  for (var b = 0; b < bt.length; b++) {
    if (bt[b] && bt[b].paired && bt[b].name) paired[String(bt[b].name)] = true
  }
  var output = audio && audio.output ? audio.output : null
  var onAirplay = !!output && output.transport === "airplay"
  var listed = sound && Array.isArray(sound.devices) ? sound.devices : []
  var fresh = !!sound && !!output && sound.output === output.uid
  var airplay = []
  for (var d = 0; d < listed.length; d++) {
    var name = String(listed[d].name || "")
    if (!name || known[name]) continue
    var row = { uid: "", name: name, picker: true }
    if (paired[name]) {
      row.transport = "bluetooth"
      row.active = false
      outputs.push(row)
    } else {
      row.transport = "airplay"
      row.active = onAirplay && fresh && !!listed[d].selected
      airplay.push(row)
    }
  }
  return { outputs: outputs, airplay: airplay, airplayKnown: !onAirplay || (fresh && sound.devices !== null) }
}

// Why a read or a press of macOS's Sound list did not work, by the app's code.
function soundFailureText(code) {
  if (code === "busy") return "Close Control Center on the Mac and try again."
  if (code === "no-device") return "That device went offline."
  if (code === "interrupted") return "A click stopped the switch. Try again."
  if (code === "unsupported") return "We can't read this macOS sound list yet."
  return "The Mac didn't answer. Try again."
}

// 0 left ... 0.5 centre ... 1 right, as the label beside BALANCE.
function balanceLabel(value) {
  var shift = Math.round((clamp01(value) - 0.5) * 200)
  if (shift === 0) return "CENTER"
  return (shift < 0 ? "LEFT " : "RIGHT ") + Math.abs(shift) + "%"
}

function clamp01(v) {
  var n = Number(v)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(1, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    outputVolumeName: outputVolumeName,
    isHeadphones: isHeadphones,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph,
    deviceLabel: deviceLabel,
    deviceRows: deviceRows,
    outputLists: outputLists,
    balanceLabel: balanceLabel,
    soundFailureText: soundFailureText,
    clamp01: clamp01
  }
}

import QtQuick
import Quickshell
import Quickshell.Io

// The Mac's sound beyond omacvm-bridge's audio payload, asked from OmacVM.app
// with `omacvm sound` (this VM's control port): the outputs macOS's own Sound
// list offers, AirPlay speakers among them, a press of one, and the output's
// balance.
//
// For the list and for a press the app opens Control Center on the Mac, off
// screen. That takes about a second, and Control Center has the Mac's
// keyboard meanwhile, so no key reaches the VM. So the list is asked only
// when the panel asks, never on a timer, and a press waits in the app
// until macOS has connected the speaker: the request on its way is the row's
// "connecting".
Item {
  id: sound
  visible: false

  // The app answered: false in a VM without it, and with an older app.
  property bool available: false
  // macOS lets OmacVM read Control Center (Accessibility).
  property bool accessibility: false
  // The Mac's output when this was read, as omacvm-bridge names it.
  property string output: ""
  // { value: 0 left ... 1 right, settable }, or null: the output has none.
  property var balance: null
  // [{ name, selected }] as macOS listed them last, or null: not read yet;
  // and the Mac's output then, which the checkmarks are for.
  property var devices: null
  property string devicesOutput: ""

  // The device whose press is on its way, and whether the list is being read.
  property string pressing: ""
  readonly property bool reading: listProc.running && pressing === ""
  readonly property bool busy: listProc.running
  // Why the last read or press did not work (the app's code, or "offline"),
  // for a few seconds.
  property string failure: ""

  // Until the app echoes it back, the panel shows the balance asked for.
  property real pendingBalance: -1
  readonly property real balanceValue: pendingBalance >= 0 ? pendingBalance : (balance ? balance.value : 0.5)

  readonly property var command: ["/usr/bin/env", "/usr/local/bin/omacvm", "sound"]

  signal answered()

  function refresh() {
    if (!stateProc.running && !listProc.running) stateProc.running = true
  }

  function read() { run(["read"], "") }

  function press(name) { run(["press", name], name) }

  // The Mac's settings where the person lets OmacVM read the list.
  function allow() { Quickshell.execDetached(command.concat(["allow"])) }

  function run(words, name) {
    if (listProc.running) return
    failure = ""
    pressing = name
    listProc.command = command.concat(words, ["--json"])
    listProc.running = true
  }

  function setBalance(v) {
    if (!balance || !balance.settable) return
    pendingBalance = Math.max(0, Math.min(1, v))
    balanceSend.restart()
  }

  // Takes the state of `omacvm sound --json`. Answers "" then, the code of
  // the app's refusal ({"code"}), or "offline" for anything else.
  function take(text) {
    var a = null
    try { a = JSON.parse(String(text || "").trim()) } catch (e) { a = null }
    if (!a || typeof a.accessibility !== "boolean") return a && a.code ? String(a.code) : "offline"
    available = true
    accessibility = a.accessibility
    output = a.output || ""
    balance = a.balance || null
    if (Array.isArray(a.devices)) {
      devicesOutput = output
      devices = a.devices
    }
    return ""
  }

  Process {
    id: stateProc
    command: sound.command.concat(["--json"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (sound.take(text) !== "") sound.available = false
        sound.answered()
      }
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        sound.failure = sound.take(text)
        sound.pressing = ""
        // macOS took the grant away meanwhile: the state says so.
        if (sound.failure === "accessibility") { sound.failure = ""; stateProc.running = true }
        if (sound.failure !== "") failureClear.restart()
        sound.answered()
      }
    }
  }

  Timer {
    id: failureClear
    interval: 6000
    onTriggered: sound.failure = ""
  }

  // Coalesce slider drags, as the panel's volume sliders do.
  Timer {
    id: balanceSend
    interval: 60
    onTriggered: {
      if (balanceProc.running) { restart(); return }
      if (sound.pendingBalance < 0) return
      balanceProc.command = sound.command.concat(["balance", String(Math.round(sound.pendingBalance * 100)), "--json"])
      balanceProc.running = true
    }
  }

  Process {
    id: balanceProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        sound.take(text)
        if (!balanceSend.running) sound.pendingBalance = -1
      }
    }
  }
}

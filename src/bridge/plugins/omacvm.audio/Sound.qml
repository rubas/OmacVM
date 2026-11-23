import QtQuick
import Quickshell
import Quickshell.Io

// The Mac's sound beyond omacvm-bridge's audio payload, asked from OmacVM.app
// with `omacvm sound` (this VM's control port): the outputs macOS's own Sound
// list offers, AirPlay speakers among them, the modes of headphones such as
// AirPods, a press of a device or of a mode, and the output's balance.
//
// For the list and for a press the app opens Control Center on the Mac, off
// screen. That takes about a second, and Control Center has the Mac's
// keyboard meanwhile, so no key reaches the VM. So the list is asked only
// when the panel asks, never on a timer, and a press waits in the app
// until macOS has connected the speaker or selected the mode: the request on
// its way is the row's or the group's spinner.
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
  // [{ name, selected, modes? }] as macOS listed them last, or null: not read yet;
  // and the Mac's output then, which the checkmarks are for.
  property var devices: null
  property string devicesOutput: ""

  // The device or the group of modes ({ device, group }) whose press is on
  // its way, and whether the list is being read.
  property string pressing: ""
  property var switching: null
  readonly property bool reading: listProc.running && pressing === "" && !switching
  readonly property bool busy: listProc.running
  // Why the last read or press did not work (the app's code, or "offline"),
  // for a few seconds.
  property string failure: ""

  // Until the app echoes it back, the panel shows the balance asked for.
  property real pendingBalance: -1
  readonly property real balanceValue: pendingBalance >= 0 ? pendingBalance : (balance ? balance.value : 0.5)

  readonly property var command: ["/usr/bin/env", "/usr/local/bin/omacvm", "sound"]

  // The app answered or failed to; pressed: a press of a row answered with the
  // list as it stands, where macOS may keep the modes of headphones closed.
  signal answered(bool pressed)

  function refresh() {
    if (stateProc.running) return
    stateProc.command = command.concat(["--json"])
    stateProc.running = true
  }

  // Whether it asked the app: not while the app is at the last request.
  function read() { return run(["read"], "", null) }

  function press(name) { run(["press", name], name, null) }

  // An option of a device's modes, by the titles macOS gave them.
  function mode(device, group, option) {
    run(["mode", device, group, option], "", { device: device, group: group })
  }

  // The Mac's settings where the person lets OmacVM read the list. The
  // answer is the state: allowed already, when they did so meanwhile.
  function allow() {
    if (stateProc.running) return
    stateProc.command = command.concat(["allow", "--json"])
    stateProc.running = true
  }

  function run(words, name, mode) {
    if (listProc.running) return false
    failure = ""
    pressing = name
    switching = mode
    listProc.command = command.concat(words, ["--json"])
    listProc.running = true
    return true
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (sound.take(text) !== "") sound.available = false
        sound.answered(false)
      }
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pressed = sound.pressing !== ""
        sound.failure = sound.take(text)
        sound.pressing = ""
        sound.switching = null
        var failed = sound.failure !== ""
        // macOS took the grant away meanwhile: no message, the state says so.
        if (sound.failure === "accessibility") sound.failure = ""
        if (sound.failure !== "") failureClear.restart()
        sound.answered(pressed && !failed)
        // Without a list the state alone: the output and its balance now.
        if (failed) sound.refresh()
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

# 0075: AirPlay speakers and balance in the VM's audio panel

Status: accepted, built, OmacVM.app only. Needs the app update and Update VM.
Seen working on macOS 27.2.1 only; not built: a volume per speaker while
several play, and the modes of AirPods (noise control, Spatial Audio), see
"Not built".

## Context

The audio panel (`omacvm.audio`) controls the Mac's sound through OmacVM
Bridge's `/audio`: CoreAudio's devices, volume and mute. CoreAudio knows a
device only while it is connected, so the panel never showed what macOS's
own Sound list also offers: AirPlay speakers and TVs. The owner wants the
Mac's sound controlled from the VM "very Mac-like", with what macOS's Sound
module has.

What macOS gives a program, tried on macOS 27.2.1 (2026-11-20):

- No public API routes the Mac's own sound output to an AirPlay device.
  AVRouting's system context (`AVOutputContext`) and MediaPlayer's
  `MPAVRoutingController` need Apple's entitlements, and AMFI kills a binary
  that claims them. Shortcuts and Music.app give no system route.
- Bonjour (`_airplay._tcp`) finds other devices than Control Center lists: a
  MacBook that receives AirPlay is found, and is not in the Sound list.
- Control Center's Sound list is readable through Accessibility. The module
  is `controlcenter-airplay`; its one custom action opens the list, whose
  rows are `AXCheckBox` with the identifier `sound-device-<name>` and the
  value 1 for the output that plays. An `AXPress` on a row does what a click
  does: the old output's checkmark goes at once, the speaker's comes when it
  is connected (0.3 to 0.4 s for a HomePod), and CoreAudio's default output
  becomes a device with the transport AirPlay about 70 ms later. With an
  AirPlay speaker playing, a press of one of the Mac's own outputs switches
  to it alone.
- The balance is public: CoreAudio's
  `kAudioHardwareServiceDeviceProperty_VirtualMainBalance` on the output
  device. A device has it only with a volume per channel. A Studio Display's
  speakers, a Mac mini's speaker and the AirPlay device have none, and System
  Settings › Sound shows no Balance slider for them either.

What Control Center costs, measured the same day:

- Its window can be moved through Accessibility (`AXPosition` is settable).
  Moved off every display right after it opens, the window server has it on
  a display for 12 to 34 ms (five rounds), and macOS puts it back at the menu
  bar at its next opening.
- While it is open, also off screen, Control Center has the Mac's keyboard:
  keys typed then reached neither TextEdit nor anything else, and neither
  `AXRaise`, `AXMain`, `AXFrontmost` nor an activation of the app in front
  gave them back. A click anywhere closes it. Once it is closed, the app in
  front has the keyboard again without a click.
- Over an app in a full-screen Space of its own that hides the menu bar, as
  OmacVM's QEMU does (`NSApplicationPresentationHideMenuBar`), all of this
  is the same, and no menu bar shows. Over one that only auto-hides it
  (TextEdit), macOS slides the menu bar in for the session. Tried with a
  test app, not with a VM: QEMU's own key tap may behave differently.
- One round (open, list, close) takes about 1.0 s, a press of a HomePod
  about 1.5 s.

## Decision

OmacVM.app answers `GET` and `POST /omacvm/app/sound` on the VM's control
port itself (`SoundGuest`, as it answers `/omacvm/app/extra-brightness`,
ADR 0031), so it works with every Bridge:

- `GET`: `{"accessibility", "output", "balance"}`: whether macOS lets OmacVM
  use Accessibility, the output's CoreAudio UID and its balance (null: none).
  No Control Center.
- `POST {"read": true}`: + `"devices"`, every output of Control Center's
  list with its checkmark.
- `POST {"press": NAME}`: presses that row and answers the list once macOS
  is done: the row's checkmark changed, or the list moved and is as before
  again (the speaker did not connect), or after 15 s.
- `POST {"balance": 0...1}`: CoreAudio.

For a read or a press the app opens Control Center, moves it off screen,
opens the Sound list, and closes Control Center again on every way out
(`SoundPicker`). It touches nothing while Control Center is open already
(the person uses it: "busy"). It finds elements by role and identifier only;
titles and action names follow the Mac's language.

The guest is untrusted: one exact path, a body of exactly one known key, a
device only by a name the list has at that moment, and every POST only while
this VM's window is the app in front, because a session takes the Mac's
keyboard for a second. The app asks who is in front at the moment it would
open Control Center, and refuses a request that comes while a session runs
("busy") instead of queueing it: a queue would run on after the person left
the VM. The route is the feature bridge's: with it off the app answers as one
without the route. There is no rate limit: a VM in front that asks in a loop
keeps the Mac's keyboard away until the person clicks out of it.

In the VM, `omacvm sound [read | press NAME | balance PERCENT] --json` asks
the app, and the panel (`Sound.qml`) runs it:

- The panel shows CoreAudio's outputs as before. What macOS lists beyond
  them is an AirPlay speaker, in its own AIRPLAY group, or a paired
  Bluetooth headset that is not connected (the Bridge's Bluetooth list has
  its name), among the outputs. Both are switched by a press.
- Because a session costs the keyboard for a second, the panel never asks on
  a timer. It asks for the list by itself only when it opens without one, or
  when the Mac is on AirPlay and the list's checkmarks were read for another
  output (AirPlay gets a new CoreAudio UID each time it connects). Otherwise
  it shows the list it has, and the button beside AIRPLAY asks again.
- The request on its way is the row's spinner; the checkmark is macOS's.
- BALANCE shows only for an output that has one.

Without Accessibility for OmacVM the AIRPLAY group says how to allow it. It
is the permission the VM's keyboard tap already asks for (Keyboard access).

`OmacVM --sound GET | POST BODY | tree` runs the same code from a terminal:
what a VM would get, and Control Center's list as Accessibility gives it,
to send along when a macOS shows a list the app cannot read.

## Not built

- **A volume per speaker** while several AirPlay speakers play. Only one
  AirPlay speaker was there, so the sliders' place in the list is unknown.
  Several speakers at once need nothing more than a press each, but that too
  is untested.
- **AirPods' modes** (noise control, Spatial Audio). No AirPods were paired.
  Control Center's binary names `active-noise-cancellation`,
  `audio-transparency`, `spatial-audio-modes`, `on-with-headtracking` and
  `on-without-headtracking`, but not where they sit in the list.

For both: `OmacVM --sound tree` on a Mac that shows them.

## Consequences

- Control Center's identifiers are Apple's to change. A macOS without them
  answers "unsupported", and the panel says so; the rest of the panel works.
- macOS 15 to 26 are untested: the menu bar's extras moved to
  `com.apple.MenuBarAgent` in 26, and the app looks in both places.
- A read at every opening of the panel would keep the list fresh and cost
  the keyboard for a second each time; the panel does not do that.
- Control Center names a row by the device's name alone. Of two devices
  with one name, a press reaches the first.

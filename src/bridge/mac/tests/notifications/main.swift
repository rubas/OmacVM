// The Mac's notifications on screen, through the Bridge's own code
// (notifications.swift), for ../../test-notifications.sh:
//   notifications-live list    one line per notification it would close: subrole, then what it says
//   notifications-live close   closes them all: {"found": N, "closed": N}
import AppKit
import ApplicationServices

func onScreen() -> [(element: AXNotificationElement, action: String)] {
  let windows = NSRunningApplication.runningApplications(withBundleIdentifier: MacNotifications.notificationCenter).flatMap {
    AXNotificationElement(ref: AXUIElementCreateApplication($0.processIdentifier)).windows
  }
  return MacNotifications.closable(windows, close: MacNotifications.closeTitle())
}

switch CommandLine.arguments.dropFirst().first {
case "list":
  for n in onScreen() {
    var text: AnyObject?
    AXUIElementCopyAttributeValue(n.element.ref, kAXDescriptionAttribute as CFString, &text)
    print("\(n.element.subrole ?? "-") \((text as? String) ?? "")")
  }
case "close":
  guard let r = MacNotifications.closeOnScreen() else { print("no Accessibility permission"); exit(1) }
  print("{\"found\": \(r.found), \"closed\": \(r.closed)}")
default:
  print("usage: notifications-live list | close"); exit(2)
}

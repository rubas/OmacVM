// The Mac's banners and alerts on screen close, as their own close button
// closes them: through NotificationCenter's Accessibility actions (the
// Bridge's Accessibility permission). Which ones, and by which action:
// notifications-model.swift. POST /notifications/dismiss (server.swift) asks.
import AppKit
import ApplicationServices

struct AXNotificationElement: NotificationElement {
  let ref: AXUIElement

  var subrole: String? { value(kAXSubroleAttribute) as? String }
  var actions: [String] {
    var names: CFArray?
    return AXUIElementCopyActionNames(ref, &names) == .success ? names as? [String] ?? [] : []
  }
  var children: [AXNotificationElement] { elements(kAXChildrenAttribute) }
  var windows: [AXNotificationElement] { elements(kAXWindowsAttribute) }

  private func value(_ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(ref, name as CFString, &v) == .success ? v : nil
  }
  private func elements(_ name: String) -> [AXNotificationElement] {
    (value(name) as? [AXUIElement] ?? []).map(AXNotificationElement.init)
  }
}

extension MacNotifications {
  static let notificationCenter = "com.apple.notificationcenterui"

  /// The title of NotificationCenter's Close action: the word from its own
  /// bundle, in the Mac's languages, as it speaks them. Before macOS 15.4
  /// Foundation looks up another bundle's words only in the Bridge's own
  /// language, English: "Close".
  static func closeTitle() -> String {
    guard #available(macOS 15.4, *) else { return "Close" }
    return Bundle(path: "/System/Library/CoreServices/NotificationCenter.app")?.localizedString(
      forKey: "Close", value: "Close", table: nil,
      localizations: Locale.preferredLanguages.map(Locale.Language.init(identifier:))) ?? "Close"
  }

  /// The banners and alerts on this Mac user's screen, each with its Close action.
  static func onScreen() -> [(element: AXNotificationElement, action: String)] {
    let windows = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenter).flatMap {
      AXNotificationElement(ref: AXUIElementCreateApplication($0.processIdentifier)).windows
    }
    return closable(windows, close: closeTitle())
  }

  /// Closes every banner and alert on this Mac user's screen: how many were
  /// there, and how many closed. nil: no Accessibility permission.
  static func closeOnScreen() -> (found: Int, closed: Int)? {
    guard AXIsProcessTrusted() else { return nil }
    let found = onScreen()
    let closed = found.filter { AXUIElementPerformAction($0.element.ref, $0.action as CFString) == .success }
    return (found.count, closed.count)
  }
}

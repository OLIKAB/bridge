import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("\(ProcessInfo.processInfo.processName): could not change login item: \(error)")
        }
    }
}

/// Carries settings over once from the bundle ids an app had before it was renamed.
public enum RenamedApp {
    /// `prefixing` maps more old bundle ids to a prefix for their keys, for apps merged into this one whose keys could clash.
    public static func migrateDefaults(from oldBundleIDs: [String], prefixing prefixed: [String: String] = [:]) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateDefaults") else { return }
        defaults.set(true, forKey: "didMigrateDefaults")
        for (id, prefix) in oldBundleIDs.map({ ($0, "") }) + prefixed.map({ ($0.key, $0.value) }) {
            guard let old = defaults.persistentDomain(forName: id) else { continue }
            // The login item belongs to the old bundle, so let the new one register itself.
            for (key, value) in old where key != "didSetUpLoginItem" && !key.hasPrefix("didMigrate") && defaults.object(forKey: prefix + key) == nil {
                defaults.set(value, forKey: prefix + key)
            }
        }
    }
}

public enum Notifier {
    public static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `userInfo` comes back to the notification center's delegate when the notification is clicked.
    public static func send(title: String, body: String, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Global shortcut via Carbon, which unlike NSEvent monitors needs no Accessibility permission.
/// Each app registers one, and pressing it toggles the app's menu bar panel. Others can be given
/// an `action` of their own instead, told apart by `id`.
public final class HotKey {
    public let displayName: String
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let signature: OSType
    private let id: UInt32
    private let action: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var registered: [UInt32: HotKey] = [:]

    /// `signature` is a four-character code unique to the app, e.g. "PORT".
    public init(keyCode: Int, modifiers: Int, displayName: String, signature: String, id: UInt32 = 1, action: (() -> Void)? = nil) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.displayName = displayName
        self.signature = signature.utf8.reduce(0) { $0 << 8 | OSType($1) }
        self.id = id
        self.action = action
    }

    public var isRegistered: Bool { hotKeyRef != nil }

    public func register() {
        guard hotKeyRef == nil else { return }
        if !Self.handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let id = pressed.id
                DispatchQueue.main.async {
                    if let action = HotKey.registered[id]?.action { action() } else { MenuBarPanel.toggle() }
                }
                return noErr
            }, 1, &eventType, nil, nil)
            Self.handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        Self.registered[id] = self
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if Self.registered[id] === self { Self.registered[id] = nil }
    }
}

public enum MenuBarPanel {
    /// MenuBarExtra has no API to open it, so click its status bar button.
    public static func toggle() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = findButton(in: window.contentView) {
                NSApp.activate(ignoringOtherApps: true)
                button.performClick(nil)
                return
            }
        }
    }

    private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}

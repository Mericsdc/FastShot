import AppKit
import Carbon.HIToolbox

/// macOS's own screenshot shortcuts (System Settings › Keyboard › Keyboard Shortcuts › Screenshots).
/// While one is switched on, macOS consumes its keys before any app sees them.
enum SystemScreenshotShortcut: Int, CaseIterable, Identifiable {
    case saveScreen = 28, copyScreen = 29, saveArea = 30, copyArea = 31, options = 184

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .saveScreen: return "Ekranın resmini dosyaya kaydet"
        case .copyScreen: return "Ekranın resmini panoya kopyala"
        case .saveArea: return "Seçili alanın resmini dosyaya kaydet"
        case .copyArea: return "Seçili alanın resmini panoya kopyala"
        case .options: return "Ekran görüntüsü ve kayıt seçenekleri"
        }
    }

    /// macOS's factory setting: character, key code and Cocoa modifier flags.
    var defaultParameters: [Int] {
        switch self {
        case .saveScreen: return [51, kVK_ANSI_3, 0x120000]
        case .copyScreen: return [51, kVK_ANSI_3, 0x160000]
        case .saveArea: return [52, kVK_ANSI_4, 0x120000]
        case .copyArea: return [52, kVK_ANSI_4, 0x160000]
        case .options: return [53, kVK_ANSI_5, 0x120000]
        }
    }

    /// Area captures open FastShot's selection; the options panel opens FastShot recording.
    /// Full-screen captures stay with macOS.
    static let takeover: [SystemScreenshotShortcut] = [.copyArea, .saveArea, .options]
}

struct SystemShortcutState: Equatable {
    let combo: KeyCombo?
    let enabled: Bool
}

/// Reads macOS's screenshot shortcuts and, at the user's request, hands them to FastShot
/// by switching them off in the system (keeping a backup so they can be given back).
@MainActor
enum SystemScreenshotShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let backupKey = "system.screenshotShortcutsBackup"
    private static let absent = "absent"

    static func state(_ shortcut: SystemScreenshotShortcut) -> SystemShortcutState {
        let entry = hotkeys()[String(shortcut.rawValue)] as? [String: Any]
        let enabled = (entry?["enabled"] as? NSNumber)?.boolValue ?? true
        let parameters = ((entry?["value"] as? [String: Any])?["parameters"] as? [NSNumber])?.map(\.intValue) ?? shortcut.defaultParameters
        return SystemShortcutState(combo: combo(from: parameters), enabled: enabled)
    }

    static func states() -> [SystemScreenshotShortcut: SystemShortcutState] {
        Dictionary(uniqueKeysWithValues: SystemScreenshotShortcut.allCases.map { ($0, state($0)) })
    }

    /// The enabled macOS shortcut that would swallow `combo`, if any.
    static func conflict(for combo: KeyCombo) -> SystemScreenshotShortcut? {
        SystemScreenshotShortcut.allCases.first { let s = state($0); return s.enabled && s.combo == combo }
    }

    static var isTakenOver: Bool { UserDefaults.standard.data(forKey: backupKey) != nil }

    /// Switches the takeover shortcuts off in macOS and returns the combos FastShot should use.
    static func takeOver() async throws -> [SystemScreenshotShortcut: KeyCombo] {
        var all = hotkeys()
        var backup: [String: Any] = [:]
        var combos: [SystemScreenshotShortcut: KeyCombo] = [:]
        for shortcut in SystemScreenshotShortcut.takeover {
            let id = String(shortcut.rawValue)
            backup[id] = all[id] ?? absent
            if let combo = state(shortcut).combo { combos[shortcut] = combo }
            var entry = all[id] as? [String: Any] ?? ["value": ["parameters": shortcut.defaultParameters, "type": "standard"]]
            entry["enabled"] = false
            all[id] = entry
        }
        if !isTakenOver {
            let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
            UserDefaults.standard.set(data, forKey: backupKey)
        }
        await write(all)
        return combos
    }

    /// Puts macOS's shortcuts back exactly as they were before the takeover.
    static func restore() async {
        guard let data = UserDefaults.standard.data(forKey: backupKey),
              let backup = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        var all = hotkeys()
        for (id, original) in backup {
            if original as? String == absent { all.removeValue(forKey: id) } else { all[id] = original }
        }
        await write(all)
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private static func hotkeys() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
    }

    private static func write(_ all: [String: Any]) async {
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // Make the window server reload keyboard shortcuts now instead of at the next login.
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
            task.arguments = ["-u"]
            try? task.run()
            task.waitUntilExit()
        }.value
    }

    private static func combo(from parameters: [Int]) -> KeyCombo? {
        guard parameters.count >= 3, parameters[1] != 65535 else { return nil }
        let flags = parameters[2]
        var modifiers = 0
        if flags & 0x100000 != 0 { modifiers |= cmdKey }
        if flags & 0x20000 != 0 { modifiers |= shiftKey }
        if flags & 0x80000 != 0 { modifiers |= optionKey }
        if flags & 0x40000 != 0 { modifiers |= controlKey }
        return KeyCombo(keyCode: UInt32(parameters[1]), carbonModifiers: UInt32(modifiers))
    }
}

import AppKit
import Carbon.HIToolbox

/// A global shortcut. PC keyboards report Print Screen to macOS as F13.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let printScreen = KeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: 0)
    static let shiftPrintScreen = KeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: UInt32(shiftKey))
    static let commandShift2 = KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let commandShift7 = KeyCombo(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let controlShiftD = KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | shiftKey))

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// A recorded key press, or nil for plain typing keys that would hijack text input.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let needsModifier = !Self.functionKeys.contains(code) && code != kVK_Help
        if needsModifier && (modifiers == 0 || modifiers == UInt32(shiftKey)) { return nil }
        self.init(keyCode: UInt32(code), carbonModifiers: modifiers)
    }

    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.name(for: Int(keyCode))
    }

    static func name(for keyCode: Int) -> String {
        let special: [Int: String] = [
            kVK_F13: "Print Screen", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19", kVK_F20: "F20", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Insert",
        ]
        if let name = special[keyCode] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Shortcuts that could not be registered because another app already owns them.
@MainActor
final class HotkeyStatus: ObservableObject {
    static let shared = HotkeyStatus()
    @Published var failed: Set<KeyCombo> = []
}

/// Registers system-wide shortcuts through Carbon, which needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Registers the app's shortcuts again after a suspension ends.
    var reregister: (() -> Void)?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var suspensions = 0
    var isSuspended: Bool { suspensions > 0 }

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let id = identifier.id
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4653_6874), id: id) // 'FSht'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[id] = reference
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        handlers.removeAll()
    }

    /// Releases every shortcut so its keys reach the app normally: while a shortcut is being
    /// recorded, or while the capture overlay uses ⌘-keys of its own. Calls nest.
    func suspend() {
        suspensions += 1
        if suspensions == 1 { unregisterAll() }
    }

    func resume() {
        guard suspensions > 0 else { return }
        suspensions -= 1
        if suspensions == 0 { reregister?() }
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }
}

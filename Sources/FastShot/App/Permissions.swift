import AVFoundation
import AppKit
import CoreGraphics

@MainActor
enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks once through the system prompt; afterwards explains where the switch lives.
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let firstAsk = !UserDefaults.standard.bool(forKey: "permissions.screenAsked")
        UserDefaults.standard.set(true, forKey: "permissions.screenAsked")
        if firstAsk, CGRequestScreenCaptureAccess() { return true }
        let alert = NSAlert()
        alert.messageText = "Ekran kaydı izni gerekiyor"
        alert.informativeText = "FastShot'ın ekran görüntüsü ve video alabilmesi için Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı bölümünde FastShot'ı açın. İzni verdikten sonra FastShot'ı yeniden başlatın."
        alert.addButton(withTitle: "Sistem Ayarlarını Aç")
        alert.addButton(withTitle: "Yeniden Başlat")
        alert.addButton(withTitle: "Vazgeç")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: openScreenRecordingSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
        return false
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

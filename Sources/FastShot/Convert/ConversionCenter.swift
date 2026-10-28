import AppKit
import FastShotCore
import SwiftUI

/// Runs conversions one batch at a time, shows progress for slow ones and
/// reports the results.
@MainActor
final class ConversionCenter {
    static let shared = ConversionCenter()

    private var queue: [(urls: [URL], format: ConversionFormat)] = []
    private var current: Task<Void, Never>?

    func convert(_ urls: [URL], to format: ConversionFormat) {
        let files = urls.filter { FileConverter.family(of: $0) != nil }
        guard !files.isEmpty else { return }
        queue.append((files, format))
        runNext()
    }

    func cancel() {
        queue.removeAll()
        current?.cancel()
    }

    private func runNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = Task { [weak self] in
            await self?.run(job.urls, job.format)
            self?.current = nil
            self?.runNext()
        }
    }

    private func run(_ urls: [URL], _ format: ConversionFormat) async {
        let prefs = Preferences.shared
        let folders = Dictionary(uniqueKeysWithValues: urls.map { ($0, destination(for: $0)) })
        for folder in Set(folders.values) { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let title = "\(format.title) biçimine dönüştürülüyor"
        let progress = ProgressHUD.Model()
        progress.title = title
        progress.detail = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) dosya"
        // Quick conversions finish before the progress panel would even appear.
        let reveal = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !Task.isCancelled { ProgressHUD.show(progress) { ConversionCenter.shared.cancel() } }
        }
        defer {
            reveal.cancel()
            ProgressHUD.hide()
        }

        var outputs: [URL] = []
        var failures: [String] = []
        let merges: Bool = { if case .imagesToPDF = format.kind { return urls.count > 1 }; return false }()
        let batches: [[URL]] = merges ? [urls] : urls.map { [$0] }
        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { break }
            if batches.count > 1 { progress.detail = "\(index + 1)/\(batches.count) · \(batch[0].lastPathComponent)" }
            let share = 1 / Double(batches.count), base = Double(index) * share
            do {
                outputs += try await FileConverter.convert(batch, to: format, folder: { folders[$0] ?? $0.deletingLastPathComponent() },
                                                           quality: prefs.jpegQuality) { fraction in
                    Task { @MainActor in progress.value = base + fraction * share }
                }
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(batch[0].lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !outputs.isEmpty {
            if prefs.revealAfterConvert { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            let summary = outputs.count == 1 ? "\(format.title) olarak kaydedildi" : "\(outputs.count) dosya \(format.title) olarak kaydedildi"
            Toast.show(summary, symbol: "arrow.triangle.2.circlepath", detail: outputs[0].lastPathComponent, actionTitle: "Göster") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failures.count == 1 ? "Bir dosya dönüştürülemedi" : "\(failures.count) dosya dönüştürülemedi"
            alert.informativeText = failures.prefix(8).joined(separator: "\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func destination(for url: URL) -> URL {
        let prefs = Preferences.shared
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        switch prefs.convertDestination {
        case .beside:
            let folder = url.deletingLastPathComponent()
            return FileManager.default.isWritableFile(atPath: folder.path) ? folder : downloads
        case .downloads:
            return downloads
        case .custom:
            return URL(fileURLWithPath: (prefs.convertFolder as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    /// Opens the wheel for whatever is selected in Finder. macOS asks once for
    /// permission to let FastShot read Finder's selection.
    func convertFinderSelection() {
        let source = """
        tell application "Finder"
            set chosen to selection as alias list
            set paths to {}
            repeat with item_ in chosen
                set end of paths to POSIX path of item_
            end repeat
            return paths
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
            Toast.show(denied ? "Finder erişimine izin verilmedi" : "Finder seçimi okunamadı", symbol: "exclamationmark.triangle.fill",
                       detail: denied ? "Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon › FastShot › Finder" : nil)
            return
        }
        var urls: [URL] = []
        if result.numberOfItems > 0 {
            for index in 1...result.numberOfItems {
                if let path = result.atIndex(index)?.stringValue { urls.append(URL(fileURLWithPath: path)) }
            }
        } else if let path = result.stringValue {
            urls.append(URL(fileURLWithPath: path))
        }
        urls = urls.filter { !$0.hasDirectoryPath }
        guard !urls.isEmpty else {
            Toast.show("Finder'da dönüştürülecek dosyaları seçin", symbol: "cursorarrow.click.2")
            return
        }
        ConversionWheel.shared.show(files: urls, at: NSEvent.mouseLocation, interactive: true)
    }

    /// Lets the user pick files, then offers the wheel for them.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Dönüştürülecek dosyaları seçin (aynı türden: görüntü, video, ses, PDF veya belge)"
        panel.prompt = "Seç"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        ConversionWheel.shared.show(files: panel.urls, at: CGPoint(x: screen.midX, y: screen.midY), interactive: true)
    }
}

/// A small panel at the bottom of the screen for conversions that take a while.
@MainActor
enum ProgressHUD {
    final class Model: ObservableObject {
        @Published var title = ""
        @Published var detail = ""
        @Published var value: Double = 0
    }

    private static var panel: NSPanel?

    static func show(_ model: Model, cancel: @escaping () -> Void) {
        hide()
        let host = NSHostingView(rootView: ProgressHUDView(model: model, cancel: cancel))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.midX - host.fittingSize.width / 2, y: visible.minY + 70))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ProgressHUDView: View {
    @ObservedObject var model: ProgressHUD.Model
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ProgressView(value: min(max(model.value, 0), 1)).frame(width: 220)
            }
            Button("İptal", action: cancel).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .hudBackground(radius: 14)
        .padding(14)
    }
}

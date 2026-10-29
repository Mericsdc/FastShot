import AppKit
import FastShotCore
import SwiftUI

/// Runs what the wheels start: conversions, tools and actions. Slow work is
/// queued one batch at a time with a progress panel; results are announced
/// with a notice that can reveal them in Finder.
@MainActor
final class ConversionCenter {
    static let shared = ConversionCenter()

    private struct Job {
        /// Shown while working, e.g. "JPEG biçimine dönüştürülüyor".
        let title: String
        /// Completes "… dosya ___", e.g. "JPEG olarak kaydedildi".
        let done: String
        let urls: [URL]
        /// All files form one batch (merging, archiving several items).
        let together: Bool
        let work: ([URL], URL, @escaping @Sendable (Double) -> Void) async throws -> [URL]
    }

    private var queue: [Job] = []
    private var current: Task<Void, Never>?

    func perform(_ item: WheelItem, on urls: [URL]) {
        switch item.kind {
        case .convert(let format): convert(urls, to: format)
        case .tool(let tool): run(tool, on: urls)
        case .action(let action): run(action, on: urls)
        }
    }

    func convert(_ urls: [URL], to format: ConversionFormat) {
        let files = urls.filter { FileConverter.family(of: $0) != nil }
        guard !files.isEmpty else { return }
        let quality = Preferences.shared.jpegQuality
        let merges: Bool = { if case .imagesToPDF = format.kind { return files.count > 1 }; return false }()
        enqueue(Job(title: "\(format.title) biçimine dönüştürülüyor", done: "\(format.title) olarak kaydedildi", urls: files, together: merges) { batch, folder, progress in
            try await FileConverter.convert(batch, to: format, folder: { _ in folder }, quality: quality, progress: progress)
        })
    }

    // MARK: Tools

    private func run(_ tool: FileTool, on urls: [URL]) {
        switch tool {
        case .edit:
            AppController.shared.openInEditor(urls)
        case .crop:
            if let url = urls.first { CropWindowController.show(url) }
        case .recognizeText:
            guard let url = urls.first, let image = ImageExporter.load(url) else { return }
            Task {
                do {
                    let text = try await TextRecognizer.recognize(image)
                    if text.isEmpty {
                        Toast.show("Metin bulunamadı", symbol: "text.viewfinder")
                    } else {
                        Output.copy(text: text)
                        Toast.show("Metin panoya kopyalandı", symbol: "text.viewfinder", detail: "\(text.split(separator: "\n").count) satır")
                    }
                } catch {
                    Output.showError(error, title: "Metin tanınamadı")
                }
            }
        case .compress:
            enqueue(Job(title: "Sıkıştırılıyor", done: tool.doneText, urls: urls, together: false) { batch, folder, progress in
                [try await FileTools.compress(batch[0], folder: folder, progress: progress)]
            })
        case .metadata:
            enqueue(Job(title: "Meta veriler temizleniyor", done: tool.doneText, urls: urls, together: false) { batch, folder, _ in
                [try await FileTools.stripMetadata(batch[0], folder: folder)]
            })
        case .background:
            enqueue(Job(title: "Arka plan ekleniyor", done: tool.doneText, urls: urls, together: false) { batch, folder, _ in
                [try FileTools.addBackground(batch[0], folder: folder)]
            })
        case .removeAudio:
            enqueue(Job(title: "Ses kaldırılıyor", done: tool.doneText, urls: urls, together: false) { batch, folder, progress in
                [try await FileTools.removeAudio(batch[0], folder: folder, progress: progress)]
            })
        case .mergePDF:
            enqueue(Job(title: "PDF'ler birleştiriliyor", done: tool.doneText, urls: urls, together: true) { batch, folder, _ in
                [try FileTools.mergePDFs(batch, folder: folder)]
            })
        }
    }

    // MARK: Actions

    private func run(_ action: FileAction, on urls: [URL]) {
        switch action {
        case .zip:
            enqueue(Job(title: "ZIP arşivi oluşturuluyor", done: "ZIP olarak arşivlendi", urls: urls, together: true) { batch, folder, _ in
                [try await FileTools.zip(batch, folder: folder)]
            })
        case .unzip:
            enqueue(Job(title: "Arşiv açılıyor", done: "arşivden çıkarıldı", urls: urls, together: false) { batch, folder, _ in
                [try await FileTools.unzip(batch[0], folder: folder)]
            })
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                Toast.show("AirDrop kullanılamıyor", symbol: "exclamationmark.triangle.fill", detail: "Wi-Fi ve Bluetooth'un açık olduğundan emin olun")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .copyToClipboard:
            if urls.count == 1, FileConverter.family(of: urls[0]) == .image, let image = ImageExporter.load(urls[0]) {
                Output.copy(image: image, pointScale: ImageExporter.pointScale(of: urls[0]) ?? 1)
                Toast.show("Görüntü panoya kopyalandı", symbol: "doc.on.clipboard.fill", detail: "Mesaja veya belgeye yapıştırabilirsiniz")
            } else {
                Output.copy(fileURLs: urls)
                Toast.show(urls.count == 1 ? "Dosya panoya kopyalandı" : "\(urls.count) öğe panoya kopyalandı", symbol: "doc.on.clipboard.fill",
                           detail: "Finder'da ⌘V ile yapıştırın")
            }
        case .copyPath:
            Output.copy(text: urls.map(\.path).joined(separator: "\n"))
            Toast.show(urls.count == 1 ? "Yol kopyalandı" : "\(urls.count) yol kopyalandı", symbol: "link", detail: urls[0].path)
        case .pin:
            pin(urls)
        case .terminal:
            openTerminal(at: urls[0])
        }
    }

    private func pin(_ urls: [URL]) {
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        for (index, url) in urls.enumerated() {
            guard let image = ImageExporter.load(url) else { continue }
            let scale = ImageExporter.pointScale(of: url) ?? 1
            var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let fit = min(1, screen.width * 0.45 / size.width, screen.height * 0.45 / size.height)
            size = CGSize(width: size.width * fit, height: size.height * fit)
            let offset = CGFloat(index) * 28
            var origin = CGPoint(x: mouse.x - size.width / 2 + offset, y: mouse.y - size.height / 2 - offset)
            origin.x = min(max(screen.minX, origin.x), screen.maxX - size.width)
            origin.y = min(max(screen.minY, origin.y), screen.maxY - size.height)
            PinWindow.show(image, pointScale: Double(scale / fit), frame: CGRect(origin: origin, size: size))
        }
    }

    private func openTerminal(at url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Queue

    func cancel() {
        queue.removeAll()
        current?.cancel()
    }

    private func enqueue(_ job: Job) {
        guard !job.urls.isEmpty else { return }
        queue.append(job)
        runNext()
    }

    private func runNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = Task { [weak self] in
            await self?.run(job)
            self?.current = nil
            self?.runNext()
        }
    }

    private func run(_ job: Job) async {
        let prefs = Preferences.shared
        let progress = ProgressHUD.Model()
        progress.title = job.title
        progress.detail = job.urls.count == 1 ? job.urls[0].lastPathComponent : "\(job.urls.count) dosya"
        // Quick work finishes before the progress panel would even appear.
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
        let batches: [[URL]] = job.together ? [job.urls] : job.urls.map { [$0] }
        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { break }
            if batches.count > 1 { progress.detail = "\(index + 1)/\(batches.count) · \(batch[0].lastPathComponent)" }
            let folder = destination(for: batch[0])
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let share = 1 / Double(batches.count), base = Double(index) * share
            do {
                outputs += try await job.work(batch, folder) { fraction in
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
            let summary = outputs.count == 1 ? job.done.prefix(1).uppercased() + job.done.dropFirst() : "\(outputs.count) dosya \(job.done)"
            Toast.show(summary, symbol: "checkmark.circle.fill", detail: outputs[0].lastPathComponent, actionTitle: "Göster") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failures.count == 1 ? "Bir dosya işlenemedi" : "\(failures.count) dosya işlenemedi"
            alert.informativeText = failures.prefix(8).joined(separator: "\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func destination(for url: URL) -> URL {
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
        guard !urls.isEmpty else {
            Toast.show("Finder'da dosya seçin", symbol: "cursorarrow.click.2")
            return
        }
        ConversionWheel.shared.show(files: urls, at: NSEvent.mouseLocation, interactive: true)
    }

    /// Lets the user pick files, then offers the wheel for them.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Dosyaları seçin: dönüştürme, araçlar ve işlemler çarkı açılacak"
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

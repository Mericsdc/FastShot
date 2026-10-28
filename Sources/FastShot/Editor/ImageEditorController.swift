import AppKit
import FastShotCore

/// Reopens a screenshot with its marks still editable.
@MainActor
final class ImageEditorController: EditorWindowController {
    let image: CGImage

    init?(project: CaptureProject, library: ProjectLibrary) {
        guard let image = ImageExporter.load(library.mediaURL(project)) else { return nil }
        self.image = image
        super.init(project: project, library: library, title: "FastShot — Görüntü düzenleyici")
        canvas.backgroundImage = image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var rendered: CGImage? {
        canvas.endTextEditing()
        return ImageExporter.flatten(background: image, canvasSize: project.canvasSize, annotations: controller.annotations)
    }

    override func projectDidSave() {
        if let rendered = ImageExporter.flatten(background: image, canvasSize: project.canvasSize, annotations: controller.annotations) {
            library.writeThumbnail(rendered, for: project)
        }
    }

    override func copyToClipboard() {
        guard let rendered else { return }
        Output.copy(image: rendered, pointScale: project.pixelScale)
        Toast.show("Panoya kopyalandı", symbol: "doc.on.doc.fill")
    }

    override func save() {
        guard let rendered else { return }
        do {
            let url = try Output.quickSave(image: rendered, pointScale: project.pixelScale)
            if Preferences.shared.copyWhenSaving { Output.copy(image: rendered, pointScale: project.pixelScale) }
            Toast.show("Kaydedildi", symbol: "square.and.arrow.down.fill", detail: url.lastPathComponent, actionTitle: "Göster") { Output.reveal(url) }
        } catch {
            Output.showError(error, title: "Görüntü kaydedilemedi")
        }
    }

    override func saveAs() {
        guard let rendered else { return }
        let prefs = Preferences.shared
        guard let choice = SavePanel.run(name: Output.baseName(project.createdAt), directory: prefs.imageFolderURL,
                                         formats: SavePanel.imageFormats, initial: prefs.imageFormat == .png ? 0 : 1) else { return }
        do {
            try Output.write(image: rendered, to: choice.url, format: choice.format == 0 ? .png : .jpeg, pointScale: project.pixelScale)
            Toast.show("Kaydedildi", symbol: "square.and.arrow.down.fill", detail: choice.url.lastPathComponent, actionTitle: "Göster") { Output.reveal(choice.url) }
        } catch {
            Output.showError(error, title: "Görüntü kaydedilemedi")
        }
    }
}

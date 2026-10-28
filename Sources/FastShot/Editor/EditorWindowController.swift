import AppKit
import FastShotCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorState: ObservableObject {
    @Published var exporting = false
    @Published var progress: Double = 0
}

struct EditorActions {
    var undo: () -> Void
    var redo: () -> Void
    var delete: () -> Void
    var copy: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var saveGIF: (() -> Void)?
    var exportProject: () -> Void
    var reveal: () -> Void
}

/// Stacks a toolbar, the main content and an optional bottom area, top to bottom.
final class EditorContentView: NSView {
    let top: NSView
    let center: NSView
    var bottom: NSView? { didSet { oldValue?.removeFromSuperview(); if let bottom { addSubview(bottom) }; needsLayout = true } }
    var bottomHeight: CGFloat = 0 { didSet { needsLayout = true } }

    init(top: NSView, center: NSView) {
        self.top = top
        self.center = center
        super.init(frame: .zero)
        addSubview(center)
        addSubview(top)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let topHeight = top.fittingSize.height
        let bottomHeight = bottom == nil ? 0 : self.bottomHeight
        top.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topHeight)
        center.frame = CGRect(x: 0, y: topHeight, width: bounds.width, height: max(0, bounds.height - topHeight - bottomHeight))
        bottom?.frame = CGRect(x: 0, y: bounds.height - bottomHeight, width: bounds.width, height: bottomHeight)
    }
}

/// Shared parts of the image and video editors: the canvas, its toolbar,
/// autosaving the project and exporting it as an editable `.fastshot` package.
@MainActor
class EditorWindowController: NSWindowController, NSWindowDelegate {
    var project: CaptureProject
    let library: ProjectLibrary
    let tools = ToolState(tool: .arrow)
    let controller: AnnotationController
    let canvas: CanvasView
    let state = EditorState()
    var onClose: ((EditorWindowController) -> Void)?
    private(set) var content: EditorContentView!
    private var saveTask: Task<Void, Never>?

    init(project: CaptureProject, library: ProjectLibrary, title: String) {
        self.project = project
        self.library = library
        controller = AnnotationController(tools: tools)
        canvas = CanvasView(controller: controller, canvasSize: project.canvasSize)
        canvas.letterboxColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.86, alpha: 1) }
        canvas.idleCursor = { .arrow }

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = CGSize(width: 1060, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        controller.load(project.annotations)
        controller.onChange = { [weak self] in self?.scheduleSave() }

        let actions = EditorActions(
            undo: { [weak self] in self?.controller.undo() }, redo: { [weak self] in self?.controller.redo() },
            delete: { [weak self] in self?.controller.deleteSelected() }, copy: { [weak self] in self?.copyToClipboard() },
            save: { [weak self] in self?.save() }, saveAs: { [weak self] in self?.saveAs() },
            saveGIF: supportsGIF ? { [weak self] in self?.saveGIF() } : nil,
            exportProject: { [weak self] in self?.exportProject() }, reveal: { [weak self] in self?.revealProject() })
        let toolbar = NSHostingView(rootView: EditorToolbar(tools: tools, state: state, actions: actions))
        // Frames are laid out by hand; don't let SwiftUI size constraints shrink the window.
        toolbar.sizingOptions = [.intrinsicContentSize]
        content = EditorContentView(top: toolbar, center: canvas)
        window.contentView = content

        // Open at the capture's size when it fits, leaving room for chrome.
        let chrome = CGSize(width: 40, height: toolbar.fittingSize.height + extraHeight + 60)
        let fit = min(1, (screen.width * 0.9 - chrome.width) / project.canvasSize.width, (screen.height * 0.9 - chrome.height) / project.canvasSize.height)
        let size = CGSize(width: max(window.minSize.width, project.canvasSize.width * fit + chrome.width),
                          height: max(window.minSize.height, project.canvasSize.height * fit + chrome.height))
        window.setContentSize(size)
        window.center()
        canvas.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Extra vertical space subclasses add below the canvas.
    var extraHeight: CGFloat { 0 }
    var supportsGIF: Bool { false }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Saving the project

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProject()
        }
    }

    func saveProject() {
        saveTask?.cancel()
        project.annotations = controller.annotations
        do {
            try library.save(project)
            projectDidSave()
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        } catch {
            NSLog("FastShot: could not save project: \(error)")
        }
    }

    func projectDidSave() {}

    func windowWillClose(_ notification: Notification) {
        canvas.endTextEditing()
        saveProject()
        onClose?(self)
    }

    // MARK: Actions for subclasses

    func copyToClipboard() {}
    func save() {}
    func saveAs() {}
    func saveGIF() {}

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53, controller.selected != nil {
            controller.select(nil)
            return true
        }
        if modifiers == [.command] {
            switch key {
            case "c": copyToClipboard(); return true
            case "s": save(); return true
            default: break
            }
        }
        if modifiers == [.command, .shift], key == "s" { saveAs(); return true }
        return false
    }

    func exportProject() {
        canvas.endTextEditing()
        saveProject()
        let type = UTType(filenameExtension: ProjectLibrary.packageExtension, conformingTo: .package) ?? .package
        guard let choice = SavePanel.run(name: Output.baseName(project.createdAt), directory: Preferences.shared.imageFolderURL,
                                         formats: [SavePanel.Format(title: "FastShot projesi", fileExtension: ProjectLibrary.packageExtension, type: type)]) else { return }
        do {
            try library.exportPackage(project, to: choice.url)
            Toast.show("Düzenlenebilir proje kaydedildi", symbol: "shippingbox.fill", detail: choice.url.lastPathComponent, actionTitle: "Göster") {
                Output.reveal(choice.url)
            }
        } catch {
            Output.showError(error, title: "Proje kaydedilemedi")
        }
    }

    func revealProject() { Output.reveal(library.mediaURL(project)) }
}

struct EditorToolbar: View {
    @ObservedObject var tools: ToolState
    @ObservedObject var state: EditorState
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 3) {
            ForEach(EditorTool.allCases) { tool in
                IconButton(symbol: tool.symbol, help: tool.help, selected: tools.tool == tool) { tools.tool = tool }
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            ColorSwatches(tools: tools, colors: Array(RGBAColor.palette.prefix(8)), columns: 8, swatch: 12)
            ColorPicker("", selection: Binding(get: { tools.color.swiftUI }, set: { tools.color = RGBAColor($0) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .help("Özel renk")
            SizePicker(tools: tools, axis: .horizontal, dotWidth: 18)
            IconButton(symbol: tools.filled ? "square.fill" : "square", help: "Dolgulu şekil / etiket", selected: tools.filled) { tools.filled.toggle() }
            Divider().frame(height: 22).padding(.horizontal, 4)
            IconButton(symbol: "arrow.uturn.backward", help: "Geri al (⌘Z)", action: actions.undo).disabled(!tools.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Yinele (⇧⌘Z)", action: actions.redo).disabled(!tools.canRedo)
            IconButton(symbol: "trash", help: "Seçili çizimi sil (⌫)", action: actions.delete).disabled(!tools.hasSelection)
            Spacer(minLength: 10)
            if state.exporting {
                ProgressView(value: state.progress).frame(width: 90)
                Text("%\(Int(state.progress * 100))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(action: actions.copy) { Label("Kopyala", systemImage: "doc.on.doc").labelStyle(.titleAndIcon) }
                .fixedSize()
                .help("Panoya kopyala (⌘C)")
            Button(action: actions.save) { Label("Kaydet", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
                .fixedSize()
                .buttonStyle(.borderedProminent)
                .help("Varsayılan klasöre kaydet (⌘S)")
            Menu {
                Button("Farklı kaydet…", action: actions.saveAs)
                if let saveGIF = actions.saveGIF { Button("GIF olarak kaydet", action: saveGIF) }
                Divider()
                Button("Düzenlenebilir proje olarak dışa aktar (.fastshot)…", action: actions.exportProject)
                Button("Orijinali Finder'da göster", action: actions.reveal)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .disabled(state.exporting)
        .controlSize(.regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

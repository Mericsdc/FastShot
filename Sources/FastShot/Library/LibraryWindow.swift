import AppKit
import FastShotCore
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tümü", images = "Görüntüler", videos = "Videolar"
        var id: String { rawValue }
    }

    @Published var projects: [CaptureProject] = []
    @Published var filter: Filter = .all
    let library: ProjectLibrary
    var open: (CaptureProject) -> Void = { _ in }
    private var observer: NSObjectProtocol?

    init(library: ProjectLibrary) {
        self.library = library
        reload()
        observer = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() { projects = library.allProjects() }

    var visible: [CaptureProject] {
        switch filter {
        case .all: return projects
        case .images: return projects.filter { $0.kind == .image }
        case .videos: return projects.filter { $0.kind == .video }
        }
    }

    func thumbnail(_ project: CaptureProject) -> NSImage? {
        NSImage(contentsOf: library.thumbnailURL(project)) ?? (project.kind == .image ? NSImage(contentsOf: library.mediaURL(project)) : nil)
    }

    func copy(_ project: CaptureProject) {
        guard project.kind == .image, let image = ImageExporter.load(library.mediaURL(project)),
              let rendered = ImageExporter.flatten(background: image, canvasSize: project.canvasSize, annotations: project.annotations) else {
            open(project)
            return
        }
        Output.copy(image: rendered, pointScale: project.pixelScale)
        Toast.show("Panoya kopyalandı", symbol: "doc.on.doc.fill")
    }

    func delete(_ project: CaptureProject) {
        let alert = NSAlert()
        alert.messageText = "Bu yakalama silinsin mi?"
        alert.informativeText = "Orijinal dosya ve çizimler geçmişten kalıcı olarak silinir. Daha önce dışa aktardığınız dosyalar etkilenmez."
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "Vazgeç")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? library.delete(project)
        reload()
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.filter) {
                    ForEach(LibraryModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                Text("\(model.visible.count) yakalama").foregroundStyle(.secondary).font(.system(size: 12))
                Button {
                    NSWorkspace.shared.open(model.library.root)
                } label: { Label("Klasörü aç", systemImage: "folder") }
            }
            .padding(12)
            Divider()
            if model.visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Henüz yakalama yok").font(.headline)
                    Text("Print Screen veya ayarladığınız kısayolla ekran görüntüsü alın; kopyaladığınız ya da kaydettiğiniz her yakalama burada düzenlenebilir olarak saklanır.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)], spacing: 14) {
                        ForEach(model.visible) { project in card(project) }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private func card(_ project: CaptureProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = model.thumbnail(project) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: project.kind == .video ? "film" : "photo").font(.system(size: 30)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 4) {
                    Image(systemName: project.kind == .video ? "video.fill" : "photo.fill")
                    if project.kind == .video, let duration = project.duration { Text(TimelineView.format(duration, precise: false)) }
                    if !project.annotations.isEmpty { Text("· \(project.annotations.count) çizim") }
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.6)))
                .foregroundStyle(.white)
                .padding(6)
            }
            Text(dateFormatter.string(from: project.createdAt)).font(.system(size: 12, weight: .medium))
            Text("\(Int(project.canvasSize.width * project.pixelScale)) × \(Int(project.canvasSize.height * project.pixelScale))")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(project) }
        .contextMenu {
            Button("Düzenle") { model.open(project) }
            if project.kind == .image { Button("Panoya kopyala") { model.copy(project) } }
            Button("Orijinali Finder'da göster") { Output.reveal(model.library.mediaURL(project)) }
            Divider()
            Button("Sil…", role: .destructive) { model.delete(project) }
        }
        .help("Düzenlemek için çift tıklayın")
    }
}

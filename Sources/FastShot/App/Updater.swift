import AppKit
import Combine

/// Looks for newer FastShot for macOS releases (tags `macos-vX.Y.Z` with a `FastShot-macOS.zip` asset on
/// github.com/Mericsdc/FastShot, published by scripts/release-macos.sh) and installs one in place.
/// Only a copy installed in an Applications folder checks.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let releasesAPI = URL(string: "https://api.github.com/repos/Mericsdc/FastShot/releases?per_page=30")!
    static let releasesPage = URL(string: "https://github.com/Mericsdc/FastShot/releases")!
    static let assetName = "FastShot-macOS.zip"
    static let tagPrefix = "macos-v"

    struct Release {
        let version: [Int]
        let downloadURL: URL
        let size: Int
        let page: URL
        var versionString: String { version.map(String.init).joined(separator: ".") }
    }

    enum Status: Equatable { case idle, checking, upToDate, available, downloading, failed }

    @Published private(set) var status: Status = .idle
    @Published private(set) var available: Release?
    @Published private(set) var error: String?
    @Published private(set) var lastChecked: Date?

    private var timer: Timer?

    static var currentVersionString: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    static var currentVersion: [Int] { parse(currentVersionString) ?? [0, 0, 0] }

    /// Copies run from a build folder (development) never update themselves.
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    static func parse(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    /// Checks a little after the start, then every six hours, while automatic checks are on.
    func start() {
        guard Self.isInstalled else { return }
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Preferences.shared.checkForUpdates { await check(userAsked: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in
                if Preferences.shared.checkForUpdates { await Updater.shared.check(userAsked: false) }
            }
        }
    }

    func check(userAsked: Bool) async {
        guard status != .checking, status != .downloading else { return }
        status = .checking
        do {
            available = try await newest()
            error = nil
            lastChecked = Date()
            status = available == nil ? .upToDate : .available
            if let release = available {
                Toast.show("FastShot \(release.versionString) hazır", symbol: "arrow.down.circle.fill", detail: "Yüklü sürüm: \(Self.currentVersionString)",
                           actionTitle: "Güncelle") { Task { await Updater.shared.install() } }
            } else if userAsked {
                Toast.show("FastShot güncel", symbol: "checkmark.seal.fill", detail: "Sürüm \(Self.currentVersionString)")
            }
        } catch {
            self.error = (error as? URLError) != nil ? "GitHub'a ulaşılamadı. İnternet bağlantınızı denetleyin." : error.localizedDescription
            status = .failed
            if userAsked { Toast.show("Güncellemeler denetlenemedi", symbol: "exclamationmark.triangle.fill", detail: self.error) }
        }
    }

    /// The newest release with a macOS download that is newer than this copy, or nil.
    private func newest() async throws -> Release? {
        var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FastShot/\(Self.currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var best: Release?
        for release in releases {
            guard release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                  let tag = release["tag_name"] as? String, tag.hasPrefix(Self.tagPrefix),
                  let version = Self.parse(String(tag.dropFirst(Self.tagPrefix.count))) else { continue }
            for asset in release["assets"] as? [[String: Any]] ?? [] where asset["name"] as? String == Self.assetName {
                guard let link = asset["browser_download_url"] as? String, let url = URL(string: link) else { continue }
                if best.map({ $0.version.lexicographicallyPrecedes(version) }) ?? true {
                    best = Release(version: version, downloadURL: url, size: asset["size"] as? Int ?? 0,
                                   page: URL(string: release["html_url"] as? String ?? "") ?? Self.releasesPage)
                }
            }
        }
        guard let best, Self.currentVersion.lexicographicallyPrecedes(best.version) else { return nil }
        return best
    }

    /// Downloads the new app, swaps it in for this one and relaunches.
    func install() async {
        guard let release = available, status == .available else { return }
        status = .downloading
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("FastShot-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let zip = work.appendingPathComponent(Self.assetName)
            try fileManager.moveItem(at: downloaded, to: zip)
            if release.size > 0, (try fileManager.attributesOfItem(atPath: zip.path)[.size] as? Int) != release.size {
                throw UpdateError.incomplete
            }
            let unpacked = work.appendingPathComponent("app", isDirectory: true)
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
            try ditto.run()
            ditto.waitUntilExit()
            let newApp = unpacked.appendingPathComponent("FastShot.app")
            guard ditto.terminationStatus == 0, let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.notFastShot }
            _ = try fileManager.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp)
            Permissions.relaunch()
        } catch {
            self.error = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            status = .failed
            Output.showError(error, title: "Güncelleme kurulamadı")
        }
    }

    enum UpdateError: LocalizedError {
        case incomplete, notFastShot
        var errorDescription: String? {
            switch self {
            case .incomplete: return "İndirilen dosya eksik."
            case .notFastShot: return "İndirilen dosya bir FastShot uygulaması değil."
            }
        }
    }
}

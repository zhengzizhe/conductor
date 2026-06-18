import AppKit
import Foundation

/// 基于 GitHub Releases 的版本更新：手动/自动检测 + 带进度下载对应芯片的 DMG。
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let repo = "zhengzizhe/conductor"
    static var releasesPageURL: URL { URL(string: "https://github.com/\(repo)/releases")! }

    struct Release: Equatable {
        let version: String      // tag 去掉可选的 v 前缀
        let notes: String
        let htmlURL: URL
        let assetName: String
        let assetURL: URL
        let assetSize: Int64
    }

    struct InstallPrompt: Identifiable, Equatable {
        let version: String

        var id: String { version }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(Release)
        case downloading(Release)
        case downloaded(Release, localURL: URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var downloadProgress: Double = 0
    @Published var installPrompt: InstallPrompt?
    @Published var autoCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckEnabled, forKey: "update.autoCheck")
            if autoCheckEnabled { scheduleAutoCheck() } else { autoCheckTimer?.invalidate() }
        }
    }

    let currentVersion: String

    /// tab 栏按钮的小圆点：有新版（含下载中/已下载）时亮。
    var updateAvailable: Bool {
        switch phase {
        case .available, .downloading, .downloaded: return true
        default: return false
        }
    }

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var autoCheckTimer: Timer?
    private let pendingUpdateStore = PendingUpdateStore()
    /// 自动检测间隔：6 小时。
    private static let autoCheckInterval: TimeInterval = 6 * 60 * 60

    private init() {
        currentVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        autoCheckEnabled = UserDefaults.standard.object(forKey: "update.autoCheck") as? Bool ?? true
        if autoCheckEnabled {
            // 启动稍等几秒再查，别跟首屏抢网络/CPU。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.check(manual: false)
            }
            scheduleAutoCheck()
        }
    }

    func check(manual: Bool) async {
        // 下载中/已下载不要被后台检查覆盖状态。
        switch phase {
        case .downloading, .downloaded: return
        case .checking: return
        default: break
        }
        phase = .checking
        do {
            let release = try await Self.fetchLatestRelease()
            if Self.isNewer(release.version, than: currentVersion) {
                phase = .available(release)
            } else {
                phase = .upToDate(Date())
            }
        } catch {
            // 自动检查失败保持安静，手动检查才显示错误。
            if manual {
                phase = .failed(error.localizedDescription)
            } else if case .checking = phase {
                phase = .idle
            }
        }
    }

    func download(_ release: Release) {
        guard downloadTask == nil else { return }
        phase = .downloading(release)
        downloadProgress = 0
        let task = URLSession.shared.downloadTask(with: release.assetURL) { [weak self] temp, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.downloadTask = nil
                self.progressObservation = nil
                if let error {
                    // 用户主动取消不算失败。
                    if (error as? URLError)?.code == .cancelled {
                        self.phase = .available(release)
                    } else {
                        self.phase = .failed(error.localizedDescription)
                    }
                    return
                }
                guard let temp else {
                    self.phase = .failed("download failed")
                    return
                }
                do {
                    let dest = Self.downloadDestination(for: release.assetName)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: temp, to: dest)
                    self.phase = .downloaded(release, localURL: dest)
                    self.installPrompt = InstallPrompt(version: release.version)
                } catch {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in self?.downloadProgress = progress.fractionCompleted }
        }
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func openDownloaded() {
        guard case .downloaded(_, let localURL) = phase else { return }
        NSWorkspace.shared.open(localURL)
    }

    func revealDownloaded() {
        guard case .downloaded(_, let localURL) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([localURL])
    }

    func installDownloadedAndRestart() {
        guard case .downloaded(_, let localURL) = phase else { return }
        pendingUpdateStore.clear()
        installPrompt = nil
        launchInstaller(dmgURL: localURL, reopenAfterInstall: true, terminateApp: true)
    }

    func installDownloadedLater() {
        guard case .downloaded(let release, let localURL) = phase else { return }
        pendingUpdateStore.save(PendingUpdate(version: release.version, dmgPath: localURL.path))
        installPrompt = nil
    }

    func installPendingUpdateOnQuitIfNeeded() {
        guard let pending = pendingUpdateStore.load() else { return }
        let dmgURL = URL(fileURLWithPath: pending.dmgPath)
        guard FileManager.default.fileExists(atPath: dmgURL.path) else {
            pendingUpdateStore.clear()
            return
        }
        launchInstaller(dmgURL: dmgURL, reopenAfterInstall: false, terminateApp: false)
    }

    @discardableResult
    private func launchInstaller(dmgURL: URL, reopenAfterInstall: Bool, terminateApp: Bool) -> Bool {
        do {
            let plan = try UpdateInstallerPlan.bundled(
                dmgURL: dmgURL,
                reopenAfterInstall: reopenAfterInstall)
            let process = Process()
            process.executableURL = plan.executableURL
            process.arguments = plan.arguments
            try process.run()
            if terminateApp {
                NSApp.terminate(nil)
            }
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func scheduleAutoCheck() {
        autoCheckTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autoCheckInterval, repeats: true) { _ in
            Task { @MainActor in await UpdateManager.shared.check(manual: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCheckTimer = timer
    }

    private static func downloadDestination(for assetName: String) -> URL {
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return downloads.appendingPathComponent(assetName)
    }

    // MARK: - GitHub release discovery

    private enum UpdateCheckError: LocalizedError {
        case badLatestResponse(Int)
        case cannotResolveLatestTag
        case assetUnavailable(Int)

        var errorDescription: String? {
            switch self {
            case .badLatestResponse(let status):
                return L("GitHub 更新检查返回 HTTP %ld，请稍后重试。", status)
            case .cannotResolveLatestTag:
                return L("未能解析 GitHub 最新版本，请打开 Releases 页面手动下载。")
            case .assetUnavailable(let status):
                return L("更新安装包暂不可用（HTTP %ld），请稍后重试。", status)
            }
        }
    }

    /// 不走 GitHub REST API，避免公共出口 IP 被 60 次/小时的未认证 API 限额卡住。
    /// `/releases/latest` 会 302 到 `/releases/tag/<tag>`；URLSession 跟随跳转后直接从最终 URL 取 tag。
    private static func fetchLatestRelease() async throws -> Release {
        let latestURL = URL(string: "https://github.com/\(Self.repo)/releases/latest")!
        var latestRequest = URLRequest(url: latestURL)
        latestRequest.httpMethod = "HEAD"
        latestRequest.cachePolicy = .reloadIgnoringLocalCacheData
        latestRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, latestResponse) = try await URLSession.shared.data(for: latestRequest)
        guard let latestHTTP = latestResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<400).contains(latestHTTP.statusCode) else {
            throw UpdateCheckError.badLatestResponse(latestHTTP.statusCode)
        }
        guard let tag = latestTag(from: latestHTTP.url ?? latestURL) else {
            throw UpdateCheckError.cannotResolveLatestTag
        }
        let version = displayVersion(from: tag)
        #if arch(arm64)
            let archSuffix = "arm64.dmg"
        #else
            let archSuffix = "x86_64.dmg"
        #endif
        let assetName = "Conductor-\(version)-\(archSuffix)"
        guard let assetURL = URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/\(assetName)") else {
            throw URLError(.badURL)
        }
        let assetSize = try await fetchAssetSize(assetURL)
        return Release(
            version: version,
            notes: "",
            htmlURL: URL(string: "https://github.com/\(Self.repo)/releases/tag/\(tag)")!,
            assetName: assetName,
            assetURL: assetURL,
            assetSize: assetSize)
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return "Conductor/\(version)"
    }

    private static func latestTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let tagIndex = parts.lastIndex(of: "tag") else { return nil }
        let valueIndex = parts.index(after: tagIndex)
        guard parts.indices.contains(valueIndex) else { return nil }
        let tag = parts[valueIndex]
        return tag.isEmpty ? nil : tag
    }

    private static func displayVersion(from tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private static func fetchAssetSize(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<400).contains(http.statusCode) else {
            throw UpdateCheckError.assetUnavailable(http.statusCode)
        }
        return max(0, response.expectedContentLength)
    }

    /// 语义化版本比较：按 . 分段数字比较，段数不齐补 0。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

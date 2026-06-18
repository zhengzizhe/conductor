import ConductorCore
import Foundation

/// 语言刷新令牌：`revision` 变化时 RootView 用 `.id()` 强制重建整棵视图树，
/// 让所有 `L()` 按新语言重新求值——这就是热切换不用重启的关键。
@MainActor
final class LocalizationRevision: ObservableObject {
    @Published var value = 0
}

/// 应用语言切换：
/// - 持久化：写 UserDefaults 的 `AppleLanguages`，保证下次启动的 Bundle 协商一致；
/// - 热生效：同时把运行时查表切到目标 `lproj` 子 bundle（App + ConductorCore），并 bump revision 重建 UI。
/// 选项另存 `choiceKey`，用于区分「用户显式选择」与「跟随系统」（直接读 AppleLanguages
/// 会拿到系统继承值，无法区分两者）。
enum AppLanguage {
    static let system = "system"
    static let simplifiedChinese = "zh-Hans"
    static let english = "en"

    private static let appleLanguagesKey = "AppleLanguages"
    private static let choiceKey = "conductor.languageChoice"

    @MainActor static let revision = LocalizationRevision()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideBundle: Bundle?

    /// 当前选择（无显式选择 → 跟随系统）。
    static var current: String {
        UserDefaults.standard.string(forKey: choiceKey) ?? system
    }

    static var activeBundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return overrideBundle ?? appModuleResources
    }

    /// 与当前语言选择匹配的 locale（日期/数字格式化用），跟随热切换。
    static var activeLocale: Locale {
        let choice = current
        return choice == system ? .autoupdatingCurrent : Locale(identifier: choice)
    }

    /// 启动时调用：把持久化的选择应用到运行时（含 ConductorCore）。
    @MainActor
    static func bootstrap() {
        applyRuntime(current)
    }

    /// 切换语言：持久化 + 立即热生效。
    @MainActor
    static func apply(_ choice: String) {
        let defaults = UserDefaults.standard
        switch choice {
        case simplifiedChinese, english:
            defaults.set([choice], forKey: appleLanguagesKey)
            defaults.set(choice, forKey: choiceKey)
        default:
            defaults.removeObject(forKey: appleLanguagesKey)
            defaults.removeObject(forKey: choiceKey)
        }
        applyRuntime(choice)
        revision.value += 1
        // 会话缓存里的默认标题（如“Claude 会话”）是扫描时生成的，重扫一遍换语言
        SessionManagerStore.shared.refresh(force: true)
    }

    private static func applyRuntime(_ choice: String) {
        let code: String? = choice == system ? nil : choice
        let bundle = code
            .flatMap { appModuleResources.localizedResourceBundle(for: $0) }
        lock.lock()
        overrideBundle = bundle
        lock.unlock()
        ConductorCoreLocalization.setLanguageOverride(code)
    }
}

private extension Bundle {
    func localizedResourceBundle(for code: String) -> Bundle? {
        let candidates = [code, code.lowercased()]
        for candidate in candidates {
            if let path = path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }

        let normalizedCode = code.lowercased()
        guard let resourcesURL = resourceURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: resourcesURL,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }
        return contents
            .first { url in
                url.pathExtension == "lproj"
                    && url.deletingPathExtension().lastPathComponent.lowercased() == normalizedCode
            }
            .flatMap { Bundle(url: $0) }
    }
}

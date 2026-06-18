import Foundation

/// ConductorCore 资源 bundle。**不要用 SwiftPM 生成的 `Bundle.module`**：
/// 生成的访问器只认「可执行文件同目录」与构建机的 `.build` 绝对路径，
/// 打包进 .app 后资源在 `Contents/Resources/`，在别人机器上两个路径都
/// 不存在 → `fatalError` 启动即崩（含 App Translocation 场景）。
/// 这里按真实布局解析，找不到也只回退主 bundle（文案回落中文 key），绝不崩。
let conductorCoreResources: Bundle = {
    let name = "Conductor_ConductorCore.bundle"
    let candidates = [
        Bundle.main.resourceURL,   // Conductor.app/Contents/Resources/
        Bundle.main.bundleURL,     // 裸可执行（swift run / swift build 产物目录）
    ]
    for base in candidates {
        if let url = base?.appendingPathComponent(name), let bundle = Bundle(url: url) {
            return bundle
        }
    }
    return .main
}()

/// ConductorCore 的运行时语言覆盖。`Bundle` 的语言协商在进程启动时固定，
/// 想热切换就得自己解析目标 `lproj` 子 bundle 并改从它查表。
public enum ConductorCoreLocalization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideBundle: Bundle?

    /// 传 "en" / "zh-Hans" 强制指定语言；传 nil 恢复跟随进程启动时的协商结果。
    public static func setLanguageOverride(_ code: String?) {
        let bundle = code
            .flatMap { conductorCoreResources.localizedResourceBundle(for: $0) }
        lock.lock()
        overrideBundle = bundle
        lock.unlock()
    }

    static var activeBundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return overrideBundle ?? conductorCoreResources
    }
}

/// 取本地化文案。约定：**以中文原文为 key**，缺译回落中文。
@inline(__always)
func L(_ key: String) -> String {
    ConductorCoreLocalization.activeBundle.localizedString(forKey: key, value: nil, table: nil)
}

/// 带格式参数版本。多参数用位置占位符 `%1$@`，便于翻译调序。
@inline(__always)
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(
        format: ConductorCoreLocalization.activeBundle.localizedString(forKey: key, value: nil, table: nil),
        arguments: arguments)
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

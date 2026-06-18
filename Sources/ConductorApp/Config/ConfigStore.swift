import ConductorCore
import Combine
import Foundation

/// 当前生效的配置，供全局读取与观察。SwiftUI/coordinator 观察它变化。
/// 单一真相源：`GhosttyRuntime` 启动、`AppStyle` 主题派生都从这里取。
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: AppConfig

    private let loader = ConfigLoader()

    private init() {
        config = loader.load()
        UsageCredentials.apply(config)   // 启动即把应用内 provider 配置注入进程环境
    }

    /// 重新从磁盘加载（手动触发；后续接文件监听做热更新）。
    func reload() {
        config = loader.load()
        UsageCredentials.apply(config)
    }

    /// 设置面板改配置：内存即时更新（@Published 驱动 UI）。
    func set(_ newConfig: AppConfig) {
        config = newConfig
        UsageCredentials.apply(config)
    }

    /// 把当前配置落盘到 config.yaml。
    func persist() {
        loader.save(config)
    }
}

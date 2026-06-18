import Foundation

#if DEBUG
/// 仅 DEBUG：让自动化把 MCP / Hooks workbench 的初始分段强制到指定 section，
/// 配合 debug-snapshot-window 截到「已配置」「编辑」等非默认分段的真实渲染。
/// 生产构建里不存在；workbench 的 @State 默认值只在 DEBUG 下读它。
@MainActor
enum AgentToolsDebugUI {
    static var mcpSection: String?
    static var hooksSection: String?
}
#endif

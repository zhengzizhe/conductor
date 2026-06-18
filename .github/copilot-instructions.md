# Conductor GitHub Copilot Instructions

- 先阅读根目录 `AGENTS.md`、`PLANS.md`、`harness.yaml`、`GOAL.md` 和当前任务相关文档。
- 复杂任务必须创建或更新 `docs/superpowers/plans/`、`docs/superpowers/specs/` 或相关 `docs/` 文档，并写明验收命令。
- 开启新任务前先确认 git 状态和任务边界，不要覆盖用户已有改动。
- Swift 项目使用 Swift Package Manager；核心逻辑优先放入 `Sources/ConductorCore` 并补充单元测试。
- `Sources/ConductorCore` 不依赖 AppKit、SwiftUI 或 GhosttyKit；App UI、菜单、通知和系统集成放入 `Sources/ConductorApp`。
- `Sources/ConductorCLI` 通过 socket/RPC/batch/bridge/events 等公开协议控制 App，不直接耦合 UI 内部状态。
- 自动化能力必须使用稳定 ID、结构化 JSON 输入输出和明确错误信息；GUI 与 CLI/socket 路径应复用同一套核心逻辑。
- 修改持久化 schema、配置、hook 脚本、CLI 输出或 socket/RPC 协议时，必须考虑兼容、迁移和回归测试。
- 终端渲染遵守 GhosttyKit/Metal 约束：终端容器只承载终端视图，焦点环和 chrome 与终端视图分离处理。
- 新增 UI 或明显视觉改动时，默认提供截图或说明无法截图的原因；文案走现有 localization 体系。
- 不得擅自新增用户未确认的 agent、provider、hook、系统权限、默认快捷键、联网行为或明显视觉方向。
- 默认验证命令：`swift build`、`swift test`；按范围补充 `swift test --filter ConductorCoreTests`、`swift test --filter ConductorAppTests`、`./Scripts/test-conductorctl.sh`。
- 打包或系统集成相关验证使用 `./Scripts/make-dev-cert.sh`、`./Scripts/make-app.sh`、`./Scripts/make-dmg.sh`。
- 不要终止用户正在运行的正式 Conductor；如需结束 dev app，只结束本轮启动并记录的 PID。
- 提交信息应清楚描述本次小任务；规范、核心逻辑、App UI、CLI、脚本和文档改动应尽量拆分提交。
- 交付说明必须写明验证结果、未执行的验证和残留风险。

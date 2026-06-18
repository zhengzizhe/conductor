# PLANS.md - Conductor 任务索引

## 1. 文件职责

本文件只做任务索引与进度登记，不承载完整流程细节。

详细规则见：

- `AGENTS.md`
- `harness.yaml`
- `docs/agent/WORKFLOW.md`
- `GOAL.md`

## 2. 项目分层

- `Sources/ConductorCore`：纯 Swift 核心模型、协议、持久化、分屏树、自动化协议、用量扫描、skills、hooks 和可测试业务逻辑
- `Sources/ConductorApp`：SwiftUI/AppKit 应用层、`AppCoordinator`、Ghostty 终端封装、系统集成、菜单命令、通知、工具面板和 UI
- `Sources/ConductorCLI`：`conductorctl` 命令行、socket/RPC/batch/bridge/events 等自动化入口
- `Sources/SweetCookieKit`：通用浏览器 cookie 读取能力
- `Tests/ConductorCoreTests`：核心逻辑测试
- `Tests/ConductorAppTests`：App 层、脚本、UI 协调和集成测试
- `Scripts`：GhosttyKit 准备、签名、打包、DMG、CLI 回归和审计脚本
- `docs`：产品、技术、计划、路线图和长期设计文档
- `site`：官网静态页面

## 3. 任务索引

| 任务 ID | 任务说明 | 当前状态 | 关联文档 |
| --- | --- | --- | --- |
| goal-cmux-warp-gap | 对标 cmux / Warp，补齐商业化产品级差距 | Active | `GOAL.md`, `docs/竞品差距调研-warp-cmux.md` |
| auto-relaunch-update-20260618 | 下载 GitHub Release DMG 后一键安装并重启 | Done | `docs/superpowers/specs/2026-06-18-auto-relaunch-update-design.md` |

## 4. 当前聚焦任务

当前长期目标以 `GOAL.md` 为准。普通任务开始前，应先判断是否属于该长期目标；如果是，按 `GOAL.md` 的 backlog 顺序和固定流程推进。

若用户开启新的独立任务，应先登记到本文件，再根据复杂度创建或更新 `docs/superpowers/plans/<任务名>.md`、`docs/superpowers/specs/<任务名>.md` 或相关 `docs/` 文档。

## 5. 状态维护规则

- 新任务先在本文件登记，再创建或更新对应计划文档
- 每完成计划文档中的关键节点，同步更新当前聚焦任务状态
- 规范、产品文档、技术文档和验收结果必须与代码演进同步
- 已完成任务应记录验证命令、截图或人工验收说明；如产生 commit，记录 commit hash

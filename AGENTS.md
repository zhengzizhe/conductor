# AGENTS.md - Conductor 协作规范

## 1. 项目定位

本仓库是 Conductor，一个 macOS 多 Agent 终端工作台，用来同时运行 Codex、Claude Code 和普通 shell。

核心目标：

- 以真实终端 pane 为中心组织工作区、tab、分屏、会话续聊、任务队列和待处理状态
- 用原生 macOS App 提供稳定、可接管的多 Agent 工作流，而不是聊天壳或网页终端模拟
- 通过 `conductorctl`、Unix socket、HTTP/WebSocket bridge 和 hooks 暴露可脚本化控制能力
- 把会话、用量、布局、工具配置、技能和 hook 管理做成可恢复、可审计、可渐进扩展的本地能力

## 2. 技术栈

- 语言与构建：Swift Package Manager、Swift 6 tools、主要 target 使用 Swift 5 language mode
- 平台：macOS 14+，SwiftUI + AppKit
- 终端渲染：GhosttyKit binary target，基于 libghostty 和 Metal
- 核心库：`ConductorCore` 纯 Swift 领域模型和可测试逻辑
- 应用层：`ConductorApp` 原生 App 外壳、AppKit 终端区、状态协调和系统集成
- CLI：`ConductorCLI` / `conductorctl`，通过本机 socket、batch、bridge 和事件流控制 App
- 第三方源码：`SweetCookieKit` 作为仓库内源码 target，用于浏览器 cookie 读取
- 文档与站点：`docs/` 存放设计和产品文档，`site/` 为 GitHub Pages 静态站点

## 3. 模块边界

- `Sources/ConductorCore`：数据模型、分屏树、持久化、配置、用量扫描、agent 会话识别、skills、hooks、automation 协议和引擎无关的 `TerminalSurface` 抽象
- `Sources/ConductorApp`：SwiftUI/AppKit 界面、`AppCoordinator`、Ghostty 终端封装、通知、更新、系统授权、菜单命令、内置 agent UI 和工具面板
- `Sources/ConductorCLI`：`conductorctl` 命令行入口、socket/RPC/bridge/batch/events 等自动化入口
- `Sources/SweetCookieKit`：浏览器 cookie 和本地存储读取能力，避免把业务语义放入该 target
- `Tests/ConductorCoreTests`：核心模型、解析、配置、用量、hooks、skills、automation 等纯逻辑测试
- `Tests/ConductorAppTests`：App 层、UI 协调、终端集成、hook 脚本和工具管理测试
- `Scripts`：打包、签名、GhosttyKit 准备、CLI 回归和辅助审计脚本
- `docs`：长期设计、计划、产品说明、路线图和第三方声明
- `site`：官网静态页面和发布展示资源

依赖方向：

- `ConductorCore` 不依赖 `ConductorApp`，不得引入 AppKit、SwiftUI 或 GhosttyKit 业务绑定
- `ConductorApp` 可以依赖 `ConductorCore`、`GhosttyKit`、`SweetCookieKit` 间接能力和必要系统框架
- `ConductorCLI` 通过公开自动化协议与 App 协作，不直接读取 App 内部 UI 状态
- `SweetCookieKit` 保持通用浏览器数据读取边界，不承载 Conductor 业务规则
- 自动化协议、持久化模型和 CLI 输出属于跨版本契约，修改时必须考虑兼容和回归
- UI 层只组合视图、状态和用户动作；可测试业务判断优先放入 `ConductorCore`

## 4. 分支命名管理

- 开启新任务前必须先确认当前分支；如果当前任务与现有分支主题不一致，应创建或切换到独立任务分支
- 默认新分支使用 `codex/` 前缀，除非用户明确指定其他前缀
- 新功能分支：`codex/feature-<topic>-<yyMMdd>`
- Bug 修复分支：`codex/bugfix-<topic>-<yyMMdd>`
- 文档或规范分支：`codex/docs-<topic>-<yyMMdd>`
- 分支名使用英文、数字和中划线，避免中文和空格
- 未经用户明确要求，不得把新任务改动继续叠加在无关功能分支上

## 5. 命名与注释

- Swift 类型、协议、枚举和公开 API 命名必须表达领域含义，避免泛化的 `Manager`、`Helper`、`Data` 滥用
- `ConductorCore` 中的模型和 reducer 要优先使用值语义，保持 Codable/Equatable 测试友好
- 枚举作为持久化、协议或 CLI 输出值时必须使用稳定 raw value 或明确编码字段，禁止依赖展示文案
- 对跨版本协议、持久化字段、权限行为、终端渲染限制和复杂状态机补充简洁注释
- 只在代码不自解释时写注释；避免把实现逐行翻译成注释
- 面向用户的文案应进入 localization 资源或现有文案体系，不要散落硬编码
- 新增公共类型时优先让测试覆盖可观察行为，而不是只依赖注释说明约束

## 6. 开发原则

- 核心先行：状态模型、协议和可测试逻辑优先落在 `ConductorCore`
- 原生优先：终端、快捷键、菜单、通知、授权和窗口行为遵循 macOS 习惯
- 真实终端优先：不要用文本快照或网页模拟替代 libghostty pane 的核心能力
- 兼容优先：CLI、socket RPC、持久化 schema、hook 脚本和配置文件改动必须考虑旧版本数据
- 小步验证：每次变更至少运行相关 `swift test`、构建、脚本或手动验证命令
- 可恢复：工作区、tab、pane、cwd、agent 会话 ID、关闭恢复和任务状态改动要考虑异常退出后的恢复路径
- 可接管：任何 agent 自动化流程都必须允许用户随时切回真实终端接管
- 可观测：涉及 agent 状态、token 用量、hook、自动化和 CLI 的功能应有可定位的错误信息或日志
- 最小可验收切片：只落地当前需求需要的模型、命令、界面和文档；后续设想放入 docs 或计划文档
- UI 状态边界清晰：局部展开、hover、选择态保留在视图；跨 pane、跨 tab、跨 workspace 或需持久化的状态进入协调器或 core 模型
- Metal 渲染约束优先：libghostty 终端容器内不要放非 Metal 的 layer-backed 兄弟视图；焦点环和 chrome 应与终端视图分离处理
- 工具面板能力要协议化：新增 agent、skill、hook、usage provider 或 workspace command 时，优先补齐模型、检测、配置和测试，再接 UI

## 7. AI 协作规范

本项目采用“根规范 + 设计文档 + 任务计划 + 验收命令”的轻量结构：

- 根目录 `AGENTS.md` 是所有 AI Coding Agent 的项目协作规范
- 根目录 `PLANS.md` 是任务索引与当前焦点登记，不承载完整设计细节
- 根目录 `harness.yaml` 描述标准工作流阶段、动作和默认验收入口
- `docs/agent/WORKFLOW.md` 是执行任务时的详细工作流说明
- `.github/copilot-instructions.md` 是 GitHub Copilot 的镜像入口，内容指向本文件和关键命令
- 复杂任务优先在 `docs/superpowers/plans/` 或相关 `docs/` 文件中沉淀任务计划、验收和风险
- 涉及产品方向、架构边界、协议、持久化、终端渲染或多组件交互的中型任务，必须创建或更新设计文档
- 复杂数据流、状态流转、hook/automation/RPC 交互可以补充流程图或结构图
- 不把大量背景知识塞进单个提示；长期设计沉淀到 `docs/`
- 每个任务文档必须包含可执行或可人工确认的验收方式，避免“按最佳实践”这类不可验证要求
- 提交信息使用中文或清楚的英文均可，但必须描述本次小任务完成的具体内容
- 提交粒度按目的拆分；规范、核心逻辑、App UI、CLI、脚本和文档改动同时出现时，应尽量拆成多个小提交

## 7.1 阶段隔离与多会话协作

复杂功能默认采用“阶段内共享上下文，阶段间传递冻结产物”的协作模式。

阶段规则：

- 产品探索阶段：产出用户场景、交互规则、验收标准和必要截图或草图
- 架构设计阶段：输入冻结需求和项目规范，输出技术设计、模块边界、协议和风险
- 编码实现阶段：输入冻结需求、设计和计划，输出代码、测试、脚本和实现说明
- QA / 攻击测试阶段：输入代码、测试入口和运行方式，重点寻找 bug、边界问题、数据一致性问题、安全风险和交互缺陷

冻结要求：

- 每个阶段结束必须产生可落盘产物，例如 PRD、architecture、plan、代码、测试结果、截图或 QA 报告
- 不能把“上下文中已经完成”视为交付；关键结论必须写入文件、截图、测试结果或明确报告
- 下一阶段优先读取上一阶段冻结产物，而不是依赖完整聊天过程

## 8. 自主边界与用户确认

- AI 可以提出产品、工具、样式、架构和规范建议，但不得在未获得用户明确确认前实现超出原始诉求的功能
- “多 Agent 终端工作台”不代表可以自行决定所有 agent 或工具清单；新增工具、provider、hook 或 UI 模块前要确认需求边界
- 涉及明显视觉方向、布局范式、默认快捷键、系统权限、数据上传或联网行为时，必须先说明取舍或征求确认
- 主动想法必须以“建议 / 可选方案 / 待确认项”的形式呈现，不得静默落地成代码、文档或配置
- 如果为了验证平台必须创建示例，应标注为 demo、example 或 test fixture，并在交付说明中说明用途
- 当用户指出 AI 擅自扩展范围时，后续处理优先级为：先记录规范，再征求确认，再清理越界实现

## 9. 复杂任务文档要求

复杂任务需要先做整体分析设计，并创建或更新：

- 产品文档：用户目标、核心场景、信息架构、交互路径、验收标准
- 技术文档：模块边界、状态模型、自动化协议、CLI 命令、持久化、系统权限、风险
- 任务计划：任务拆解、产出物、验证方式、截图要求和当前状态

## 10. 默认验证命令

- 全量构建：`swift build`
- 全量测试：`swift test`
- Core 测试：`swift test --filter ConductorCoreTests`
- App 层测试：`swift test --filter ConductorAppTests`
- CLI / socket / bridge 回归：`./Scripts/test-conductorctl.sh`
- 准备 GhosttyKit：`./Scripts/prepare-ghosttykit.sh`
- 创建开发签名：`./Scripts/make-dev-cert.sh`
- 打包 App：`./Scripts/make-app.sh`
- 打包 DMG：`./Scripts/make-dmg.sh`
- 快速运行 App：`swift run ConductorApp`
- CLI 帮助：`swift run conductorctl --help`
- 本地站点检查：直接打开 `site/index.html`

根据改动范围选择最小但足够的验证集合；涉及终端渲染、系统权限、通知、打包签名或 app bundle 行为时，优先验证打包后的 `Conductor.app`。

## 11. 交付标准

- 代码、测试、文档和计划同步更新
- 新增或修改核心能力时，有对应单元测试、脚本验证或明确的手动验证说明
- 新增 CLI/RPC/automation 能力时，更新帮助、协议模型和回归测试
- 新增 UI 或明显视觉改动时，默认提供截图或说明无法截图的原因
- 涉及用户数据、权限、会话恢复、hook 执行或自动化控制时，交付说明必须写明风险与验证结果
- 未完成项、跳过的验证和已知风险必须明确列出

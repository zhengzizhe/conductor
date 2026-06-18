# Conductor 开发工作流

## 1. 核心原则

- 核心先行：状态模型、协议、持久化和可测试逻辑优先放入 `ConductorCore`
- 原生优先：窗口、菜单、快捷键、通知、授权和可访问性遵循 macOS 习惯
- 真实终端优先：核心终端能力必须基于 libghostty pane，不用网页终端或文本快照替代
- 双接口优先：用户能在 GUI 做的关键动作，尽量也能通过 `conductorctl`、socket、batch 或 bridge 被 AI/脚本调用
- 兼容优先：CLI/RPC 输出、持久化 schema、hook 脚本和配置文件是契约，修改时必须考虑迁移和回归
- 原子实现：一个逻辑小任务独立完成，避免混入无关重构
- 小步验证：每个切片运行与风险匹配的构建、测试、脚本或手动验证
- 文档同步：复杂任务必须同步更新产品文档、技术文档、计划文档和验收结果
- 用户确认优先：新增 agent、provider、hook、系统权限、视觉方向、默认快捷键或联网行为前，先说明取舍或征求确认

## 2. 阶段一：Init

动作：

1. 阅读 `AGENTS.md`
2. 阅读 `PLANS.md`
3. 阅读 `harness.yaml`
4. 阅读 `GOAL.md`，判断任务是否属于长期对标 backlog
5. 阅读当前任务相关的 `docs/`、`docs/superpowers/plans/` 或 `docs/superpowers/specs/`
6. 判断任务类型：Core、App、CLI、Automation、Terminal、Docs、Site、Packaging 或 Fix
7. 检查 git 状态，识别用户已有改动，不覆盖无关文件

输出：

- 当前任务类型
- 涉及模块
- 任务文档位置
- 计划采用的验证命令

## 2.1 阶段隔离总则

复杂功能采用“阶段内共享上下文，阶段间传递冻结产物”：

1. 产品探索阶段可以在单会话中完成，目标是冻结用户场景、交互规则、验收标准和必要截图或草图。
2. 架构设计阶段优先只输入冻结需求、项目规范和必要约束，输出技术设计、模块边界、协议和风险。
3. 编码实现阶段只输入冻结需求、冻结设计、任务计划和必要规则，输出代码、测试、脚本和实现说明。
4. QA / 攻击测试阶段默认只输入代码入口、测试入口、运行方式和验收标准，重点质疑实现。

每个阶段结束后，主 Agent 必须判断下一阶段是否应切换新会话。如果需要切换，必须提示用户：

- 当前阶段已冻结的产物
- 下一阶段目标
- 新会话需要携带的文件清单
- 不应携带的聊天过程或未落盘假设

## 3. 阶段二：Analyze

动作：

1. 梳理用户场景和边界
2. 列出需要用户确认的产品决策，例如默认快捷键、系统权限、联网行为、视觉方向或新增 provider
3. 定义 `ConductorCore` 模型、状态流转、reducer 或服务边界
4. 涉及自动化时，定义 socket/RPC/CLI JSON 输入输出、稳定 ID、错误信息和事件流
5. 涉及持久化时，说明 schema、旧数据兼容、异常退出恢复和用户数据风险
6. 涉及终端 UI 时，复核 GhosttyKit/Metal 渲染约束
7. 更新设计文档、任务计划或 `GOAL.md` 对应条目

分析文档建议包含：

- 背景与需求
- 当前链路或已有实现
- 用户路径和状态流转
- 核心模型与模块边界
- 自动化协议或 CLI 契约
- 持久化与恢复策略
- 用户待确认决策
- 验证方案
- 风险与待确认项

## 4. 阶段三：Design

动作：

1. 更新任务计划
2. 拆分 Core、App UI、CLI/RPC、脚本、测试和文档切片
3. 明确每个子任务的产出物和验证方式
4. 明确 UI 证据要求：截图、渲染测试或手动验证说明
5. 明确提交边界；提交信息应清楚描述本次小任务

提交拆分示例：

- `核心：新增 Feed 请求状态模型`
- `自动化：补充 feed approve socket 命令`
- `界面：新增审批面板操作按钮`
- `测试：覆盖审批策略边界`
- `文档：记录 Feed 验收流程`

## 5. 阶段四：Implement

每个子任务按以下节奏执行：

1. Sync：说明当前处理的子任务
2. Core First：优先实现可测试模型、协议、reducer 或服务
3. Surface：接入 App UI、CLI、socket、hook 或脚本入口
4. Verify：运行相关测试、构建、脚本或手动验证
5. Docs：同步任务计划、设计文档或用户文档
6. Commit：如用户要求提交，按当前子任务相关文件提交

边界要求：

- `ConductorCore` 不引入 AppKit、SwiftUI 或 GhosttyKit 业务绑定
- `ConductorApp` 负责界面组合、系统集成和终端承载，不堆积可测试业务规则
- `ConductorCLI` 通过公开协议访问 App，不直接耦合 UI 内部状态
- `SweetCookieKit` 保持浏览器数据读取边界，不承载 Conductor 业务语义

## 6. 阶段五：QA

默认验证按改动范围选择：

- `swift build`
- `swift test`
- `swift test --filter ConductorCoreTests`
- `swift test --filter ConductorAppTests`
- `./Scripts/test-conductorctl.sh`
- `./Scripts/prepare-ghosttykit.sh`
- `./Scripts/make-dev-cert.sh`
- `./Scripts/make-app.sh`
- `./Scripts/make-dmg.sh`
- `swift run ConductorApp`
- `swift run conductorctl --help`

UI 交付：

- 新增页面或明显更新 UI 时，默认提供截图或说明无法截图的原因
- 涉及真实终端、通知、权限、签名、bundle id 或系统设置时，优先验证打包后的 `Conductor.app`
- 不要终止用户正在运行的正式 Conductor；如需结束 dev 进程，只结束本轮启动并记录的 PID

阶段结束：

- QA 完成后输出验收说明
- 验证失败时记录失败命令、错误原因、影响范围和下一步处理

## 7. 异常处理

- 发现逻辑堆在 UI 层：先抽出 `ConductorCore` 模型或服务，再继续实现
- 发现 CLI/socket 与 GUI 行为分叉：收敛到同一套核心逻辑
- 发现持久化或协议变更会破坏旧数据：补迁移、兼容或明确用户确认
- 发现 GhosttyKit 渲染异常：先复核 Metal layer 约束，避免在终端容器内叠加不兼容视图
- 发现系统权限或用户数据风险：停止静默落地，先说明影响并等待确认
- 验证失败：不宣称完成，记录命令输出摘要和下一步修复方案

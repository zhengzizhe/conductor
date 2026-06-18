# 内置 Agent（基于 pi）：方案与交互设计说明

> 本文件是「内置 Agent」功能开工前的设计稿，对应 `GOAL.md` 固定流程第 3 步。
> 探针已跑、命门已验（见 §2），架构无阻断。落代码前以本文为评审基准。

## 1. 定位

Conductor 今天只**编排别人的 agent**——把 `claude` / `codex` 等外部 CLI 丢进 Ghostty 终端 pane 里跑。差距文档 §1 点名的最大短板之一是 **Conductor 没有「自研 agent」**：Warp 走了自研 agent 整套路线，cmux 只能编排外部 CLI、同样没有内置 agent。

**内置 Agent = Conductor 自己的一等 agent。** 它不是终端里又跑一个 CLI，而是:

- 把开源 agent 运行时 [`pi`](https://github.com/earendil-works/pi)（earendil-works/pi，MIT，TS/Bun）的单文件二进制**打进 `Conductor.app`**；
- Conductor UI 以 `pi --mode rpc` 起一个**非 PTY 子进程**，解析 JSONL 事件流，渲染**原生面板**（不进 Ghostty pane）；
- 每次工具调用在执行前**经 Conductor 的 Feed 审批闸**，进程内、走同一条 stdin/stdout 管子。

**为什么 pi 是对的底座**：不用从零写 agent loop 和 20+ provider 归一层（`pi-ai` 已做）；MIT 可嵌入；有明确的机器驱动模式（`--mode rpc`）；它唯一缺的「权限/审批系统」恰好是 Conductor 上个迭代刚做完的 `FeedCenter`——**短板与长板互补**。

**不做什么**：不是在 `AgentLaunchCommandSnapshot` 里加 `case "pi"` 把 pi 当第 N 个外部 CLI 检测。那是「补一个 provider」，与本功能无关。

## 2. 结论先行：探针已验证什么

2026-06-16 跑过探针（无 API key，全程 `/tmp` 隔离，未碰用户 Conductor / `~/.npm` / `~/.pi`）：

| 点 | 结果 | 证据 |
|---|---|---|
| 裸驱动 `pi --mode rpc`（无 key） | ✅ | `get_state` / `get_available_models` 回 `success:true` |
| **工具审批回合（命门）** | ✅ | 扩展 `ctx.ui.confirm` → stdout `extension_ui_request{confirm}` 阻塞 → 宿主在 stdin 回 `extension_ui_response{confirmed}` → 解阻塞 |
| `tool_call` + `{block:true}` 钩子 | ✅ 注册成功 | 生产路径；真触发需 LLM 调工具 |
| `bun --compile` 单文件 + 签名 | ✅ | 61MB 二进制，`codesign --options runtime` + `allow-jit`/`allow-unsigned-executable-memory` 后照常运行 |
| 编译二进制加载外部 `.ts` 扩展 | ✅（源码层确认） | `coding-agent/src/core/extensions/loader.ts:331-343` 的 `isBunBinary` 分支用 `jiti/static`+`virtualModules` |

**未在本沙箱验、非阻塞**：整 pi 二进制 build（被本机时间钉死的 npm 镜像卡，正常 env/CI 可）；真 Gatekeeper 公证（需 Developer ID + notary）；LLM 驱动的 `tool_call` 端到端（需 provider key）。

## 3. 架构

```
Conductor.app/Contents/Resources/pi/
   pi                      ← bun --compile 单文件二进制（自带运行时，~90-110MB）
   conductor-bridge.ts     ← 桥接扩展（审批 + conductor 原生工具）
   <sibling assets>        ← copy-binary-assets 产出的 theme/worker 等

ConductorApp
 ├─ BuiltinAgentSession（ObservableObject，@MainActor）
 │    └─ Process: pi --mode rpc -e <bridge> --session-dir <conductor 管> [--provider/--model]
 │         ├─ env: CONDUCTOR_SOCKET / CONDUCTOR_PANE_ID / ANTHROPIC_API_KEY…（UsageCredentials 注入）
 │         ├─ stdin  ← JSONL 命令: prompt/steer/follow_up/abort/set_model/fork/compact…
 │         └─ stdout → JSONL: message_update(流式)/tool_execution_*/turn_*/agent_* + extension_ui_request
 ├─ BuiltinAgentPanelView（右侧原生面板，对标 FeedPanelView 挂载到 RootView）
 └─ FeedCenter（已存）← 桥接扩展的审批请求接进 submit()
```

**分层（守 `GOAL` 铁律 3a：纯逻辑抽到 `ConductorCore`）**：

- `ConductorCore/BuiltinAgent/`：RPC 协议编解码（`RPCCommand` / `RPCEvent` / `ExtensionUIRequest` 的 Codable）、JSONL 严格分帧器、事件 → transcript 模型的纯函数 reducer、审批请求映射（`ExtensionUIRequest{confirm}` → `FeedRequest`）。**全部可单测，不依赖 Process / UI。**
- `ConductorApp/BuiltinAgent/`：`BuiltinAgentSession`（持 `Process`、读写管道、接 `FeedCenter`、接 automation socket）+ `BuiltinAgentPanelView`。

**JSONL 分帧**：严格按 `\n` 切、剥尾随 `\r`（`rpc.md` 明确警告：勿用会切 `U+2028/2029` 的通用行读取器，JSON 字符串里合法）。Swift 侧自己按字节扫 `\n`。

## 4. 工具审批 = Feed（核心设计）

pi 在非交互模式默认不弹 trust prompt、放开工具——guardrail 必须 Conductor 来兜。机制：捆进包的 `conductor-bridge.ts` 扩展 `pi.on("tool_call", …)`（执行前触发、可 `return {block:true,reason}`），对非只读工具调 `ctx.ui.confirm/select`；RPC 模式下这变成 stdout 的 `extension_ui_request`，**阻塞**等 Conductor 回 `extension_ui_response`。

```
LLM 决定调 bash
  └─ pi: tool_call 钩子（桥接扩展）
       └─ ctx.ui.select("允许该工具？", ["允许","本会话允许","拒绝"])
            └─ stdout: extension_ui_request{method:"select", id, title, options}      ← pi 阻塞
                 └─ BuiltinAgentSession 收到 → 构造 FeedRequest(.permission(tool, category, detail))
                      └─ await FeedCenter.submit(request, timeout:)  → FeedDecision   ← 复用现有闸 + 策略引擎
                           └─ stdin: extension_ui_response{id, value:"允许"}
                                └─ 钩子 return（放行）或 {block:true}（拒绝）
```

要点:

- **零垫片**：不需要 Claude 那套 `conductor-approve` PreToolUse python hook，也不绕 `$CONDUCTOR_SOCKET`——审批走 Conductor 已经在驱动的同一条 stdout/stdin 管子。比现有 Claude 集成更干净，且顺手避开「真 claude 端到端卡环境」那条脆弱链路。
- **复用策略引擎**：`FeedActionCategory.infer(toolName:)` 分类；只读工具（read/grep/find/ls）走 category 默认放行，写/改/bash 弹 Feed；「本会话允许 / 记住」走 `FeedDecision` 的 `.tool`/`.category` scope → 落 `FeedPolicyStore`。**与 socket Feed 完全同一套核心逻辑**（守双接口行为对齐铁律）。
- **超时**：`FeedCenter` 软超时（默认 120s）到点自动 deny → 回 `{cancelled:true}` → 钩子按拒绝处理。
- **审计**：进 `FeedAuditEntry` 环形缓冲，`agent` 字段标 `builtin`。

## 5. 工具面

1. **pi 内置**（read/write/edit/bash/grep/find/ls）——全部经 §4 Feed 把关。
2. **Conductor 原生工具**（桥接扩展 `pi.registerTool()`，工具体调 `$CONDUCTOR_SOCKET`）：`conductor_open_pane` / `conductor_split` / `conductor_run_in_pane` / `conductor_notify` /（浏览器落地后）`conductor_open_browser`。**这是差异化**：内置 agent 不只在盒子里写代码，还能驱动工作台本身——满足「AI 驱动 conductor」的双接口卖点。
3. **MCP**（Phase 2）：pi 刻意不内置 MCP；桥接扩展把 Conductor MCP 管理台里的 server 注册成 pi 工具，让现有 MCP 工作台对内置 agent 有用。
4. **Skills**（Phase 2）：桥接扩展 `resources_discover` 钩子回 Conductor Skills 库路径，复用现有 Skills 深度。

## 6. 会话 / 成本 / 凭据 / 模型

- **会话**：`--session-dir` 指到 Conductor 管的目录（JSONL）。RPC 的 `fork`/`clone`/`switch_session`/`get_fork_messages` 接进 transcript 面板与会话管理（pi 的分支/fork 是一等特性，正好补 Conductor 会话故事）。续聊/误关恢复接现有 `AgentSessionCatalog`。
- **成本**：RPC `get_session_stats`（token + cost + contextUsage）与 `message_end.usage.cost` 流进现有 48-provider 用量面板——闭合「跑 agent → 同一个 app 看花费」。
- **凭据**：`UsageCredentials.apply()` 已在启动把 `ANTHROPIC_API_KEY` 等注入进程 env，子进程直接继承；OAuth/订阅（Claude Pro / Copilot）复用用户 `~/.pi` auth。
- **模型**：`get_available_models` / `set_model` / `set_thinking_level` → 面板模型/思考档下拉。

## 7. 交互设计说明（GOAL 第 3 步四块）

### ① 交互完整性（全状态）

- **正常态**：transcript 流式渲染（`message_update` 的 text/thinking/toolcall delta），工具调用内联展开（args + 流式输出 + 写/改的 diff），每轮 token/成本徽标。
- **空态**：未开始对话 → 引导卡（「问我改代码 / 跑命令」+ 示例 prompt + 当前 cwd/模型）。
- **加载态**：等首响有转圈；流式时有「生成中」指示 + 可中断按钮。
- **错误态**：`extension_error` / provider 错误 → 可读错误 + 重试；`auto_retry_*` 事件渲染为「第 n/3 次重试」。
- **无权限/未配置态**：无任何 provider key → 引导去配凭据（指向用量/设置），不报错不空白；二进制缺失 → 提示重装。
- **极端量**：超长 transcript 用虚拟化列表；超长 bash 输出走 pi 的 `truncated`+`fullOutputPath`，面板给「查看完整输出」。
- **反馈即时 / 可逆**：发送/中断/批准都有即时视觉反馈；工具审批是显式决策（破坏性操作天然二次确认）；`abort` 随时可停。

### ② 人好用（GUI 一等公民）

- **多入口**：命令面板（⌘K）可搜「打开内置 Agent / 新建 Agent 会话 / 中断」；面板内输入框；右键 pane 菜单「在此目录起内置 Agent」。
- **键盘优先**：发送（⌘↵）、中断（Esc）、新会话、切模型全可键盘完成；新快捷键经 `KeyChord` 注册 + 冲突检测。
- **可发现性**：命令面板可搜、空态有引导、面板图标/文案自解释。
- **一致性**：复用现有 `Theme`（accent/语义色/间距/圆角）、`PanelWidthStore` + `PanelResizeHandle`（对标 `FeedPanelView` 挂载到 `RootView`）、SF Symbols；**不自造视觉**（守口味铁律：不发闷渐变/玻璃，官方成熟配色）。
- **本地化 + 无障碍**：文案走 `L(...)` 中英；动态字号不破版；控件可访问性标签；输入框 IME 正常。
- **性能**：主线程不卡，管道读在后台队列、`@Published` 去抖刷新；transcript 虚拟化。

### ③ AI 好调用（机器接口一等公民）

内置 agent 自身也要能被 socket 驱动（让别的 agent / 脚本驱动它），在 `AutomationService.handle()` 新增方法：

- `agent-start`（params: `cwd` / `model` / `prompt`）→ 返回 `agent:N` 短引用
- `agent-prompt` / `agent-steer` / `agent-abort`（addressing by `agent:N`）
- `agent-state` / `agent-transcript`（**query**：可读状态，不只触发）
- `agent-list`

**稳定寻址** `agent:N`；**结构化 I/O** 走现有 `AutomationProtocol`（NDJSON + `{id,ok,result|error}`）；**明确错误**用现有 `AutomationError` 码；**行为对齐**——GUI 与 socket 都打到同一个 `BuiltinAgentSession`，零分叉。

### ④ 商业化打磨

- **截图门面级**：默认状态面板即好看、信息密度合适（transcript + 内联工具/diff + 成本徽标），可直接进官网截图/release notes。
- **首次体验**：未配 provider 给清晰引导（怎么连），而非报错。
- **文案专业**：无 TODO/占位/调试串；错误文案给「下一步怎么办」。

## 8. 数据/状态模型 + 测试计划（守 testing-bar）

`ConductorCore/BuiltinAgent/` 纯逻辑 + 单测，覆盖**正常 + 边界 + 异常**：

- **JSONL 分帧器**：半包/粘包/`\r\n`/空行/超长行/含 `\n` 的 JSON 字符串。
- **RPC Codec**：所有 command/event/extension_ui_request 的 Codable 往返；未知 event 类型不崩（向前兼容）。
- **审批映射**：`ExtensionUIRequest{confirm/select}` → `FeedRequest`（工具名 → `FeedActionCategory.infer`）；`FeedDecision` → `extension_ui_response`（allow/deny/scope）。
- **transcript reducer**：delta 累积、工具 start/update/end 配对、乱序/缺失 end 的容错。

`swift test` 全绿 + `swift build` 通过 + **dev app 真跑 + UI 截图**（独立 bundle id `dev.conductor.goal`，独立 `CONDUCTOR_STATE_DIR`，绝不碰用户实例，只 kill 自己的 PID）。验收含一轮真 LLM 调工具 → Feed 弹窗 → 批准/拒绝端到端截图。

## 9. 打包 / 签名

- **`Scripts/prepare-pi.sh`**（对标 `prepare-ghosttykit.sh`）：`bun build --compile --target=bun-darwin-arm64`/`bun-darwin-x64`（pi `scripts/build-binaries.sh` 现成）→ `Vendor/pi/<arch>/`，连带 `copy-binary-assets` 的 sibling 资源 + `conductor-bridge.ts`。
- **`Package.swift` `.copy("Vendor/pi")` / `make-app.sh`** → `Resources/pi/`。
- **签名**：新建 `Conductor.entitlements`（仓库现无），加 `com.apple.security.cs.allow-jit` + `com.apple.security.cs.allow-unsigned-executable-memory`；先签嵌套 binary（hardened runtime），再签 app，再 notarize。
- **禁用 pi `update --self`**：钉版本，靠发 app 升级 pi（自更新破坏签名）。
- **体积**：bun --compile ≈ 90-110MB/arch（探针实测 trivial 程序就 61MB），可接受但记上。

## 10. 风险与未决

1. **JIT 公证**：本地 hardened-runtime + entitlements 已跑通；真 Gatekeeper 公证需在正式签名/notary 流水线上最后确认。
2. **RPC 协议稳定性**：pi 迭代快——钉 pi 版本，桥接扩展 + Swift Codec 对齐该版本，加协议版本探测/降级。
3. **sibling 资源**：编译 binary 期望同目录有 theme/export-html/image-resize-worker 等；headless rpc 真正需要的子集要跑一遍确认，别漏。
4. **无沙箱**：pi 无权限系统，guardrail 全靠 Feed + 工具白名单 + cwd 限定（+ 将来 worktree）。v1 用 Feed 拦写/bash 可接受。
5. **`project_trust`**：headless 下桥接扩展直接处理或配 `defaultProjectTrust`，别卡启动。

## 11. 分期 + 完成定义

- **Phase 1（MVP）**：`BuiltinAgentSession` + `BuiltinAgentPanelView`（transcript / 输入 / 中断 / 模型选）+ 桥接扩展接 `FeedCenter` + `prepare-pi.sh`/entitlements/make-app.sh + 凭据继承 + session-dir 管理。→ 一个真·Feed 把关、原生面板的内置 agent。
- **Phase 2（深度）**：Conductor 原生工具、会话 fork/branch UI、成本进用量面板、MCP 桥、Skills 注入、§7③ 的 socket 方法。

**完成定义**（守铁律 2/3）：商业化产品级（能进截图/release notes）；`swift test` 全绿（含 `ConductorCore/BuiltinAgent` 新测）；dev app 真跑 + 一轮真 LLM 调工具→Feed 端到端截图留证。

---

参考实现：pi 源码 `packages/coding-agent/docs/{rpc,extensions,sessions,session-format}.md`、`packages/agent/docs/hooks.md`。探针脚本与产物见 `/tmp/pi-spike`（`conductor-bridge.ts` / `drive.mjs`）。

---

## 12. 详细实施计划（file-level WBS）

§11 是战略分期，本节是可照着开工的工作分解。按**依赖**排序，每个里程碑独立可验（守铁律 3）。

**依赖图**：M1（纯逻辑，无依赖）→ 解锁 M3；M2（二进制，无依赖，可与 M1 并行）→ 解锁 M3 真跑；M3 → 解锁 M4；M5 建立在全部之上。
**从哪开工**：**M1**——纯逻辑、`swift test` 立刻可验、不依赖打包环境，先把 RPC 协议建模这块风险打掉。

### M1 — `ConductorCore/BuiltinAgent` 纯逻辑 + 单测（无 Process / 无 UI）

目标：把 RPC 协议、分帧、transcript reducer、审批映射全部建成可单测的纯逻辑。

新增文件：

- `Sources/ConductorCore/BuiltinAgent/RPCProtocol.swift`
  - `RPCCommand`（Codable，`type` 分派）：`prompt` / `steer` / `follow_up` / `abort` / `new_session` / `get_state` / `get_messages` / `set_model` / `cycle_model` / `get_available_models` / `set_thinking_level` / `compact` / `fork` / `clone` / `switch_session` / `get_fork_messages` / `set_session_name` / `get_session_stats`。
  - `RPCEvent`（Codable，未知 `type` 落 `.unknown` 不崩——向前兼容）：`agent_start/end`、`turn_start/end`、`message_start/update/end`、`tool_execution_start/update/end`、`queue_update`、`compaction_start/end`、`auto_retry_start/end`、`extension_error`。
  - `AssistantMessageDelta`（union）：`text_start/delta/end`、`thinking_*`、`toolcall_start/delta/end`、`done`、`error`。
  - `ExtensionUIRequest`（`select` / `confirm` / `input` / `editor` / `notify` / `setStatus` / `setWidget` / `setTitle` / `set_editor_text`）+ `ExtensionUIResponse`（`value` / `confirmed` / `cancelled`）。
- `Sources/ConductorCore/BuiltinAgent/JSONLFramer.swift`
  - `struct JSONLFramer { mutating func feed(_ data: Data) -> [String] }`：按 `\n` 切、剥尾随 `\r`、缓存半包、跳空行。
- `Sources/ConductorCore/BuiltinAgent/AgentTranscript.swift`
  - 值类型：`TranscriptItem`（user / assistant(text+thinking) / toolCall(status: pending/running/done/error, args, output, diff?) / notice）。
  - `struct TranscriptReducer { mutating func apply(_ event: RPCEvent) -> [TranscriptChange] }`：delta 累积、tool start/update/end 按 `toolCallId` 配对、缺 end 容错。
- `Sources/ConductorCore/BuiltinAgent/ApprovalMapper.swift`
  - `ExtensionUIRequest(confirm/select)` → `FeedRequest(.permission(tool, FeedActionCategory.infer(toolName:), detail))`；从 title/message 抽工具名与命令。
  - `FeedDecision` → `ExtensionUIResponse`（allow→`confirmed:true`/选「允许」，deny→`confirmed:false`，scope 透传给后续记忆）。

新增测试 `Tests/ConductorCoreTests/BuiltinAgent/`：

- `JSONLFramerTests`：半包 / 粘包 / `\r\n` / 空行 / 超长行 / JSON 字符串内含 `\n`。
- `RPCCodecTests`：每个 command/event/extension_ui_request 编解码往返；未知 event 不崩。
- `TranscriptReducerTests`：delta 累积、乱序、缺 end、并行工具。
- `ApprovalMapperTests`：工具名→category；decision→response 三态。

验证闸：`swift build` ✅ + `swift test` 全绿。

### M2 — 桥接扩展 + 打包/签名流水线（可与 M1 并行）

目标：能从 `Conductor.app` 里跑起签名后的 pi 二进制，并加载我们的桥接扩展。

新增/改动：

- `Vendor/pi/conductor-bridge.ts`（生产版）：`project_trust` 自动信任；`tool_call` 钩子 → `ctx.ui.select(["允许","本会话允许","拒绝"])` → `{block:true}` 拒绝；（M5 再加 `registerTool` 原生工具）。
- `Scripts/prepare-pi.sh`（对标 `prepare-ghosttykit.sh`）：`bun build --compile --target=bun-darwin-arm64`/`-x64` → `Vendor/pi/<arch>/pi` + `copy-binary-assets` 的 sibling 资源 + `conductor-bridge.ts`。
- `Conductor.entitlements`（新建）：`com.apple.security.cs.allow-jit`、`com.apple.security.cs.allow-unsigned-executable-memory`（+ 现有所需）。
- `Package.swift`：`.copy("Vendor/pi")`（或在 make-app 里拷）。
- `Scripts/make-app.sh`：拷 `Resources/pi/`；先 `codesign --options runtime --entitlements Conductor.entitlements` 嵌套 binary，再签 app。
- 关掉 `pi update --self`（钉版本）。

验证闸：`Resources/pi/<arch>/pi --version` 跑通；签名后仍跑；用一个最小脚本 `pi --mode rpc -e conductor-bridge.ts` 复现探针的 confirm 回合（沙箱外/CI 环境，本机 npm 镜像时间钉死无法 build）。

### M3 — `BuiltinAgentSession`（实时驱动）

目标：进程 + 管道 + 接 FeedCenter，跑通「发 prompt → 流式 → 工具调用弹 Feed → 决策回写」。

新增 `Sources/ConductorApp/BuiltinAgent/BuiltinAgentSession.swift`（`@MainActor`，`ObservableObject`）：

- `start(cwd:model:)`：`Process` 起 `Resources/pi/pi --mode rpc -e <bridge> --session-dir <conductor 管>`；env 注 `CONDUCTOR_SOCKET` / `CONDUCTOR_PANE_ID` / 继承 `UsageCredentials` 注入的 key。
- 后台读 `stdout` → `JSONLFramer` → 解码：`RPCEvent` 经 `TranscriptReducer` 刷 `@Published transcript`；`ExtensionUIRequest{confirm/select}` → `ApprovalMapper` → `await FeedCenter.submit(_,timeout:)` → 写 `ExtensionUIResponse` 到 `stdin`。
- `send(_:RPCCommand)`、`abort()`、`stop()`；进程退出/错误（`extension_error`、stderr）surface 到 `@Published status`。
- `@Published`：`transcript` / `isStreaming` / `model` / `sessionStats(cost)` / `error`。

验证闸：`swift build`；一个 debug 入口（隐藏命令/测试 harness）真起一次（用 `~/.pi` 已配的 zai/GLM），日志确认事件流 + 一次 confirm→Feed 回合（dev 实例，独立 state dir，**不碰用户 Conductor**）。

### M4 — `BuiltinAgentPanelView`（原生面板 UI）

目标：商业化门面级的 transcript 面板，挂进主窗。

新增/改动：

- `Sources/ConductorApp/UI/BuiltinAgentPanelView.swift`：transcript 虚拟化列表（user/assistant/thinking 折叠/工具调用内联 + 写改 diff + 流式输出 + 「查看完整输出」）；输入框（⌘↵ 发送、Esc 中断）；模型/思考档下拉；成本徽标；§7① 全状态（空/加载/错误/未配置/极端量）。
- `RootView.swift`：对标 `FeedPanelView` 挂载（`.frame(width:)` + `PanelResizeHandle` + `.transition`）。
- `AppCoordinator`：`builtinAgentPresentation` 状态 + `openBuiltinAgent()/closeBuiltinAgent()`；`PanelWidthStore` 加条目。
- `CommandRegistry`（⌘K：打开/新建会话/中断）+ `KeyChord` 快捷键（冲突检测）。
- 文案走 `L(...)` 中英；复用 `Theme` accent/语义色（守口味铁律）。

验证闸：`swift test` 全绿；dev app（独立 bundle id `dev.conductor.goal`、`CONDUCTOR_STATE_DIR`，只 kill 自己 PID）真跑，各状态**截图留证**。

### M5 — 双接口 + 深度（Phase 2）

目标：让 AI 也能驱动内置 agent，并长出 conductor 独有深度。

- `AutomationService.handle()` 新增：`agent-start` / `agent-prompt` / `agent-steer` / `agent-abort` / `agent-state`(query) / `agent-transcript`(query) / `agent-list`；稳定寻址 `agent:N`；走现有 `AutomationProtocol` + `AutomationError`；**与 GUI 同打一个 `BuiltinAgentSession`**（零分叉）。
- 桥接扩展 `pi.registerTool()`：`conductor_open_pane` / `conductor_split` / `conductor_run_in_pane` / `conductor_notify`（工具体调 `$CONDUCTOR_SOCKET`）。
- 成本进现有用量面板；会话 `fork`/`clone`/branch UI；MCP 桥（Conductor MCP 管理台 server → pi 工具）；Skills 注入（`resources_discover`）。

验证闸：socket 方法单测/集成；**一轮真 LLM 调工具 → Feed 弹窗 → 批准/拒绝端到端截图**（消掉 §2 的 ⚠️）。

### 里程碑验收口径

每个 M：`swift build` 通过 + `swift test` 全绿（含新测）+ 涉及 UI 的 dev app 真跑 + 截图。全功能收官＝M1-M5 全绿 + 真 LLM 端到端截图 + 能进 release notes。

---

## 13. 第二轮调研：剩余 gap 全部查实（2026-06-16）

**真 LLM 端到端（zai/GLM，活跑，非命令模拟）**

- **ALLOW**：LLM 调 bash → `tool_call` 钩子 → `ctx.ui.confirm` → `extension_ui_request{confirm}` 阻塞 → host `confirmed:true` → 工具执行，`tool_execution_end isError=false`，输出 `conductor-builtin-agent-ok`。
- **DENY**：同上 host `confirmed:false` → 桥接返回 `{block:true,reason}` → `tool_execution_end isError=true`，结果文本 `Denied via Conductor Feed`，**工具未执行**，拒绝理由回灌给 LLM。

→ 真 LLM 驱动的 `tool_call → Feed → 执行/拦截`两条路径都活验通过。§2 的「推断未跑」消除。

**凭据路径（确认）**：pi-ai 从**环境变量**读 key（`ZAI_API_KEY`/`Z_AI_API_KEY`、`ANTHROPIC_API_KEY` 等）；`~/.pi` 不存在也能跑。Conductor `UsageCredentials.apply()` 正是 `setenv` 注入 → 子进程继承 → **零新增管线**。

**许可证（清白）**：依赖树全许可（MIT 67 / Apache-2.0 44 / BSD-3 14 / ISC 8 / BlueOak 5 / 0BSD 1），**无 GPL/AGPL/SSPL**。5 个 UNKNOWN 全是 pi 自家 `pi-extension-*`（归 monorepo MIT）。义务：补 `THIRD_PARTY_NOTICES`（Apache-2.0 要留 NOTICE）。

**sibling 资源**：`copy-binary-assets` 拷 `package.json`/README/CHANGELOG/theme/assets/export-html/docs/examples/`photon_rs_bg.wasm`。headless rpc 至多需 `package.json`（取版本）+ photon wasm（仅图像输入）；其余 TUI/export 专用。随 binary 全带即可，体积小。

**非 PTY 起进程 + sandbox**：Conductor 未开 app-sandbox、仓库无 `.entitlements`，且已在 `NotificationManager`/`TTYCommandRunner`/`ProviderVersionDetector` 多处 `Process()` 起子进程。**无阻断、无需新能力**。

**两处方案修正（读真源码抓到，必须落进 M1）**：
1. `ApprovalMapper` 不能直接套 `FeedActionCategory.infer`——它精确匹配的是 Claude/Codex **大写**工具名（`Bash`/`Read`/`Write`），pi 是**小写**（`bash`/`read`/`write`/`edit`/`grep`/`find`/`ls`）。关键字兜底接得住 bash/write/edit/read/grep，但 **`find`/`ls` 会落 `.other`**（只读却误弹）。Mapper 要补 pi 工具名表（`find`/`ls`→`readFile`）。
2. `FeedCenter` **非单例**（`FeedCenter.swift:38-39` 是 `@MainActor final class … ObservableObject`，由 `AppCoordinator` 持有 `c.feedCenter`）。`BuiltinAgentSession` 必须注入**同一实例**，否则审批与 GUI 面板对不上。其 `submit(_,timeout:) async -> FeedDecision`（`FeedCenter.swift:62`）签名与方案一致。

**仍只源码层确认、未活跑（低风险，留 M2/CI）**：`bun --compile` 二进制加载外部扩展并做回合——`loader.ts:331-343` 的 `isBunBinary` 分支专为此设计，但本沙箱 npm 镜像时间钉死、build 不出整二进制（npm pi 已证行为、trivial bun 二进制已证签名，仅「编译二进制 + 我们的扩展」这一组合没合跑）。真 Gatekeeper 公证需 Developer ID，留发布流水线。

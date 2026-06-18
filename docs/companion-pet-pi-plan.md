# 通知宠物伙伴（基于内置 pi Agent）：方案与交互设计说明

> 本文件是「通知宠物」功能开工前的设计稿，对应 `GOAL.md` 固定流程第 3 步。
> 落代码前以本文为评审基准。底座是已落地的[内置 Agent（pi）](builtin-agent-pi-plan.md)——本功能不新起 agent，只给它「一张脸」。

## 1. 定位

Conductor 已经有内置 Agent（`BuiltinAgentSession` 驱动打包的 `pi --mode rpc`），但它的状态只活在右侧 transcript 面板里——**你不盯着面板就不知道 agent 在干嘛**。通知宠物补的就是这块：一只待在桌面角落的像素精灵，**瞥一眼就知道 pi 在想 / 在等你批 / 跑完了 / 挂了**。

**通知宠物 = 内置 Agent 的一张环境化的脸。** 它不是新系统、不接通用 LLM、不另起进程，而是：

- 订阅**同一个** `BuiltinAgentSession`（`@Published phase` / `transcript`）与 `FeedCenter`（`@Published pending`）；
- 把这些信号归约成**宠物心情**（`PetMood`），映射到精灵图集的动画行；
- 反过来也是 pi 的一个**最小输入口**：点宠物 → 小输入框 → `session.prompt(...)`，气泡里流式吐回复。

一个 session、两个渲染器：右侧面板看细节，桌宠瞥一眼。这同时踩中调研标杆 [openpets](https://github.com/alterhq/openpets) 的「**一只共享宠物代表 agent 状态**」哲学，和本仓库反复强调的**双接口 / 零分叉**铁律（GUI 与 socket 同打一个 `BuiltinAgentSession`，宠物只是又一个消费者）。

**不做什么**：不接独立的通用聊天 LLM（那会偏离「通知」主线、退化成套壳聊天框，违背 depth-first）；不画 Live2D / 不上 WebGL（重、且唯一字面对标项目 ViviPet 是 GPL，见 §2）；不做养成数值（饱食/心情值那套是 VPet 的游戏化深度，与「通知」无关）。深度从**通知**自己长（审批气泡内联决策、贴边溜达、语音播报），不从外面套维度。

## 2. 结论先行：调研已验证什么

2026-06-16 调研了开源桌宠 / AI 伴侣生态，结论是**这个需求已有人做得几乎一模一样，且协议干净可抄**：

| 项目 | 是什么 | 技术 / License | 我们取什么 |
|---|---|---|---|
| **[alterhq/openpets](https://github.com/alterhq/openpets)** ⭐ | 一只共享 macOS 桌宠，给多个 AI agent 当状态显示 | Swift6 / SwiftUI+AppKit · **MIT** | **架构**：语义状态→动画行映射、`notify` 状态模型（running/review/done/failed/waiting/message）、threadId 气泡去重、8×9 sprite atlas（Codex Pets 格式） |
| **[alvinunreal/openpets](https://github.com/alvinunreal/openpets)** | 同名姊妹，Plugin SDK v3 更成熟 | Swift macOS · MIT | 热点（hotspot）槽位抽象（留作 P3 信息位参考） |
| **[raman0c17/pet-therapy](https://github.com/raman0c17/pet-therapy)** | 上架 App Store 的 macOS 桌宠 | SwiftUI 100% · **MIT** | **渲染机制**：透明 `NSWindow` 帧动画、窗口当障碍物（`CGWindowListCopyWindowInfo`）、行为状态机 |
| [suntianc/ViviPet](https://github.com/suntianc/ViviPet) | 字面意义「AI 通知桌宠」 | Electron+Live2D · ⚠️ **GPL-3.0** | **只看不抄**：speech bubble + 可选 TTS（system `say`）的轻量版灵感 |
| [LorisYounger/VPet](https://github.com/LorisYounger/VPet) | 桌宠养成 / mod 生态天花板 | WPF/.NET · 自定义 | 交互深度灵感（不在 v1 范围） |

**许可证（清白）**：openpets、pet-therapy 均 **MIT**——架构与渲染技巧可直接借用，义务仅补 `THIRD_PARTY_NOTICES`。ViviPet（GPL-3.0）**不碰其代码**，只学产品形态。

**关键洞察（已与现有代码核对）**：openpets 的精髓是 agent 发**语义状态**、宠物自己映射动画行——而 `BuiltinAgentSession.Phase`（`idle/starting/ready/streaming/stopped/failed`）+ `FeedCenter.pending` **几乎就是现成的语义状态源**，无需 agent 端改一行。详见 §4。

**非阻塞、留待落地确认**：实际精灵美术（采用 Codex Pets 8×9 格式可蹭现成资源，否则需自绘一套）；透明窗在多显示器 / Spaces 下的位置持久化（已有 `ToastHUD` 的 `NSPanel` 范式打底）。

## 3. 架构

```
ConductorApp
 ├─ BuiltinAgentSession（已存，@MainActor / ObservableObject）
 │    @Published phase / transcript / modelLabel    ← 唯一信号源
 │    func prompt(_:) / abort()                       ← 宠物也复用的输入口
 ├─ FeedCenter（已存，@MainActor / ObservableObject）
 │    @Published pending: [FeedRequest]               ← 待决审批（= "需要你"）
 │    func submit(_,timeout:) async -> FeedDecision    ← 审批闸
 │
 ├─ Companion/CompanionController（新，@MainActor / ObservableObject）
 │    订阅上面两个 @Published → PetStateReducer → @Published mood/bubble
 │    持有并定位 CompanionWindow；点宠物→session.prompt；气泡按钮→feedCenter.resolve
 ├─ Companion/CompanionWindow（新，NSPanel）
 │    对标 ToastHUD.swift:52-62 的透明浮层，但开鼠标事件、去 .transient、可拖拽持久化
 └─ Companion/CompanionView（新，SwiftUI）
      精灵帧动画 + speech bubble + 点击冒出的输入框

ConductorCore/Companion/（纯逻辑，可单测，不碰 Process/UI/AppKit）
 ├─ PetMood            心情枚举（= 精灵动画行语义）
 ├─ AgentSignal        Core 层快照（App 把 Phase + pending 映射进来，避免 Core 依赖 App 类型）
 ├─ PetStateReducer    (AgentSignal, now) -> PetMood 的纯状态机（含庆祝/瞌睡的时序）
 ├─ SpriteAtlas        8×9 图集：mood → 行；frameIndex → 列
 └─ BubbleCoalescer    turn/session key → 气泡去重（threadId 思路）
```

**分层（守 `GOAL` 铁律 3a：纯逻辑抽到 `ConductorCore`）**：心情归约、图集行映射、气泡去重全是纯函数，进 `ConductorCore/Companion/`，**全部可单测、不依赖 AppKit/Process**。`ConductorApp/Companion/` 只做窗口、渲染、与现有 session/FeedCenter 接线。

**注意依赖顺序**：右侧 `BuiltinAgentPanelView` 尚未落地（属内置 Agent 计划的 M4）。宠物**不依赖**该面板存在，只依赖 `BuiltinAgentSession` 实例存在；「点宠物跳面板」在面板落地前先降级为「拉起/聚焦内置 Agent 入口」。

## 4. 状态映射（核心设计）

agent 端**零改动**。`CompanionController` 把现有信号映射成 Core 的 `AgentSignal`，`PetStateReducer` 归约成 `PetMood`：

| pi 信号（现有） | openpets 语义 | `PetMood` | 精灵表现 |
|---|---|---|---|
| `phase == .streaming` | `running` | `.thinking` | 转圈 / 敲键盘 |
| `feedCenter.pending` 非空 | `review` / `waiting` | `.needsYou` | **敲玻璃看你**（最高优先级，盖过 thinking） |
| `.streaming → .ready` 收尾 | `done` | `.celebrating` | 蹦一下（**瞬态**：N 秒后回落 idle） |
| `phase == .failed` | `failed` | `.sad` | 蔫了 / 叹气 |
| `.ready` / `.stopped` 静置超时 | idle | `.sleeping` | 打盹 |
| `.idle` / `.ready` 活跃 | idle | `.idle` | 待机微动 |
| `transcript` 新 assistant 文本 | `message` | （叠加气泡） | speech bubble |

**优先级**：`needsYou` > `sad` > `thinking` > `celebrating`(瞬态) > `idle`/`sleeping`。审批待决永远盖过一切——「需要你」是宠物存在的第一理由。

**为什么放 `PetStateReducer` 纯逻辑**：`celebrating` 是瞬态（done 后显示几秒回落）、`sleeping` 靠静置计时——这些时序状态机最容易出错，必须可单测。reducer 不读时钟，`now` 由调用方传入（保证测试确定性，守 testing-bar 的「边界 + 异常」）。

**气泡去重（`BubbleCoalescer`）**：同一轮（turn）的多条 assistant delta 复用一个气泡、就地更新，不刷屏——抄 openpets 的 threadId 思路，key 用 session+turn。

## 5. 渲染机制（抄 pet-therapy）

- **透明浮层**：`CompanionWindow` 用 `NSPanel(styleMask:[.borderless,.nonactivatingPanel])`、`isOpaque=false`、`backgroundColor=.clear`、`level=.floating`、`collectionBehavior=[.canJoinAllSpaces]`——**对标 `ToastHUD.swift:52-62`**。与 ToastHUD 的差异：**开鼠标事件**（`ignoresMouseEvents=false`，要点击/拖拽）、**去掉 `.transient`**（常驻而非一闪）、位置持久化（`@AppStorage` 存角落/坐标）。`.nonactivatingPanel` 保证点宠物不抢主窗焦点。
- **精灵帧动画**：SwiftUI `Image` + 计时器切帧，从 `SpriteAtlas` 取 `(row=mood, col=frameIndex)`。采用 **Codex Pets 8×9 图集格式**（行=状态），可蹭现成宠物美术、兼容那个正在成形的生态标准；图集 PNG 进 `Resources/`。
- **speech bubble**：贴宠物上方的圆角小气泡，复用现有 `Theme`/`AppStyle` token（accent/语义色/`subtleFill`/圆角），**不自造视觉**（守口味铁律：不发闷渐变/玻璃，官方成熟配色）。
- **窗口当障碍物**（P3）：`CGWindowListCopyWindowInfo` 读其他窗口矩形，让宠物贴边溜达不挡你——抄 pet-therapy 的 Windows-Detector 思路。

## 6. 双向：宠物也是 pi 的最小输入口

不止显示。点宠物 → 上方冒一个小输入框 → 回车 → `session.prompt(text)`（复用现有「流式中自动 steer 排队」逻辑，见 `BuiltinAgentSession.swift:103`）→ 气泡里流式吐回复。重活（多轮 transcript / 工具 diff）仍在右侧面板；宠物负责「随手问一句 + 瞥状态」。

**审批气泡内联决策**（差异化深度）：`mood==.needsYou` 时气泡直接给 `允许 / 本会话允许 / 拒绝` 按钮——本质是 `feedCenter.resolve(id:decision:)`（`FeedCenter.swift:80`）的另一个入口，与右侧 Feed 面板、socket 完全同一套核心逻辑（守双接口行为对齐）。点宠物本体则跳/聚焦内置 Agent 面板。

## 7. 交互设计说明（GOAL 第 3 步四块）

### ① 交互完整性（全状态）

- **正常态**：心情随 `phase`/`pending` 实时切；新回复冒气泡。
- **空态**：内置 Agent 从未启动 → 宠物打盹 + 首点引导「问我点啥」。
- **加载态**：`.thinking` 转圈即加载指示；输入框发送后立即气泡占位。
- **错误态**：`.sad` + 气泡给可读错误 + 「重试 / 看详情」。
- **无权限 / 未配置态**：内置 Agent 无 provider key → 宠物不报错，气泡引导去配凭据（指向用量/设置面板）。二进制缺失 → 宠物休眠 + 提示。
- **极端量**：超长回复气泡截断 + 「在面板看全文」；高频 delta 经 `BubbleCoalescer` 去抖，不闪烁。
- **反馈即时 / 可逆**：发送 / 审批 / 中断都有即时视觉反馈；宠物可一键收起（回 menu bar），可拖拽换位，位置记住。

### ② 人好用（GUI 一等公民）

- **多入口**：命令面板（⌘K）「显示/隐藏宠物伙伴」；menu bar 开关；设置里开关 + 角落选择。
- **键盘优先**：气泡输入框 ⌘↵ 发送、Esc 收起；审批气泡可键盘选 允许/拒绝。
- **可发现性**：首次启用有一次性引导气泡说明它代表内置 Agent。
- **一致性**：复用 `Theme`/`AppStyle`、SF Symbols、`L(...)` 中英文案；**不自造视觉**（守口味铁律）。
- **不打扰**：`.nonactivatingPanel` 不抢焦点；`ignoresMouseEvents` 仅在精灵实际像素上为 false（命中测试贴形状，空白处穿透）；可全局静音 TTS。
- **性能**：帧动画用单个 `TimelineView`/计时器，静置（sleeping）降帧到近 0；`@Published` 去抖。

### ③ AI 好调用（机器接口一等公民）

宠物本身是显示层，无需独立 socket 接口——它驱动的 `prompt`/审批已由内置 Agent 计划的 `agent-*` socket 方法覆盖。仅补一个可选只读 query，让自动化/测试能断言宠物态：

- `companion-state`（query）→ 返回 `{mood, bubbleText?, pendingApprovalCount}`，走现有 `AutomationProtocol`（NDJSON + `{id,ok,result}`）。**纯可读、不触发**，主要用于端到端测试断言与脚本观测。

### ④ 商业化打磨

- **截图门面级**：一只干净像素宠物蹲在角落、气泡里流着 pi 的回复——天然适合官网 / release notes 动图。
- **首次体验**：默认**关**或低调出现，由用户主动开启（不强塞桌面浮层）；开启有清晰引导。
- **文案专业**：无 TODO / 占位 / 调试串；错误气泡给「下一步怎么办」。

## 8. 数据 / 状态模型 + 测试计划（守 testing-bar）

`ConductorCore/Companion/` 纯逻辑 + 单测，覆盖**正常 + 边界 + 异常**：

- **`PetStateReducer`**：每条 `phase` 转移 → 正确 `mood`；`pending` 非空中断 `thinking` 升 `needsYou`；`celebrating` 瞬态时序（done 后 N 秒回落 idle，期间又来 streaming 则打断庆祝）；静置超时 → `sleeping`；优先级仲裁（needsYou > sad > thinking > celebrating > idle）。
- **`SpriteAtlas`**：每个 `mood` → 正确行；`frameIndex` 越界回绕；8×9 边界。
- **`BubbleCoalescer`**：同 turn 多 delta 合一气泡；跨 turn 换新气泡；乱序 / 缺尾容错。
- **`AgentSignal` 映射**：`(Phase, pendingCount, lastAssistantText)` → 快照的纯函数往返。

`swift test` 全绿 + `swift build` 通过 + **dev app 真跑 + UI 截图**（独立 bundle id `dev.conductor.goal`、独立 `CONDUCTOR_STATE_DIR`，绝不碰用户实例，只 kill 自己 PID）。验收含**各心情截图**：thinking / needsYou（带审批气泡）/ celebrating / sad / sleeping，以及一轮真 LLM：点宠物发问 → 气泡流式 → pi 调工具 → 宠物升 needsYou → 气泡内批准 → 回 celebrating。

## 9. 资源 / 打包

- **精灵图集**：`Resources/Companion/<pet>.png`（8×9，Codex Pets 格式）+ `<pet>.json`（行→mood 元数据）。优先采用现成 Codex Pets 资源；若自绘，记一条 Aseprite 工作量（对标 pet-therapy 的「a lot of Aseprite」）。
- **许可证**：openpets / pet-therapy 借鉴义务 → 补 `THIRD_PARTY_NOTICES`；宠物美术若来自第三方需核其授权。
- 无新签名 / entitlements 需求（透明 `NSPanel` 不需要新能力，`ToastHUD` 已证）。

## 10. 风险与未决

1. **命中测试**：透明窗空白处必须鼠标穿透（不挡桌面其他点击），仅精灵像素接事件——靠 `NSView.hitTest` 按 alpha/形状裁。先做矩形命中，P3 再贴形状。
2. **多显示器 / Spaces**：`canJoinAllSpaces` + 位置持久化要在多屏下不跑飞；边界 clamp 到可见 frame。
3. **美术来源**：Codex Pets 现成资源可用性未核（决定「直接蹭」还是「自绘一套」的工作量）——P0/P1 间确认。
4. **不打扰的度**：桌面浮层天然有打扰风险——默认关、可拖走、可静音、空白穿透，四条都要落，否则会被嫌烦。
5. **依赖内置 Agent 落地节奏**：宠物 P1 起需要一个能跑的 `BuiltinAgentSession`；若该计划 M3/M4 未完，宠物先接 session 的 `phase`（已可跑），面板跳转降级（§3）。

## 11. 分期 + 完成定义

- **P0（纯逻辑）**：`ConductorCore/Companion/`（`PetMood` / `AgentSignal` / `PetStateReducer` / `SpriteAtlas` / `BubbleCoalescer`）+ 全单测。→ 心情状态机这块风险先打掉，`swift test` 立即可验，不依赖美术/打包。
- **P1（显示）**：`CompanionWindow`（透明 NSPanel，固定角落）+ `CompanionView`（精灵帧动画 + 气泡）+ `CompanionController` 订阅 `BuiltinAgentSession.$phase`/`transcript` + `FeedCenter.$pending`。→ 一只会随状态变心情的宠物。
- **P2（交互）**：点宠物→输入→`prompt()`、气泡流式、审批气泡内联 允许/拒绝（`feedCenter.resolve`）、点本体跳/聚焦内置 Agent、命令面板 + menu bar 开关、位置持久化。
- **P3（深度）**：窗口当障碍物贴边溜达、`say` TTS（默认关）、形状命中测试、多 session 一只宠物轮显/叠气泡、`companion-state` socket query。

**完成定义**（守铁律 2/3）：商业化产品级（能进截图/release notes）；`swift test` 全绿（含 `ConductorCore/Companion` 新测）；dev app 真跑 + 各心情截图 + 一轮真 LLM「点宠物发问→流式→工具审批→气泡批准」端到端截图留证。

---

## 12. 详细实施计划（file-level WBS）

按**依赖**排序，每个里程碑独立可验（守铁律 3）。**从 M1 开工**——纯逻辑、`swift test` 立刻可验、不依赖美术/打包/内置 Agent UI。

### M1 — `ConductorCore/Companion` 纯逻辑 + 单测（无 AppKit / 无 Process / 无 UI）

新增文件：

- `Sources/ConductorCore/Companion/PetMood.swift`
  - `enum PetMood: Equatable { case sleeping, idle, thinking, needsYou, celebrating, sad }`，含优先级序。
- `Sources/ConductorCore/Companion/AgentSignal.swift`
  - `struct AgentSignal: Equatable { enum Activity { case idle, starting, working, succeeded, failed, stopped }; var activity; var pendingApprovals: Int; var lastAssistantText: String?; var turnID: String? }`——Core 层快照，App 负责把 `BuiltinAgentSession.Phase` + `FeedCenter.pending` 映射进来（Core 不反向依赖 App 类型）。
- `Sources/ConductorCore/Companion/PetStateReducer.swift`
  - `struct PetStateReducer { mutating func reduce(_ signal: AgentSignal, now: TimeInterval) -> PetMood }`——纯状态机：优先级仲裁（needsYou > sad > thinking > celebrating > idle/sleeping）、`celebrating` 瞬态回落、静置 → `sleeping`。`now` 由调用方传入（确定性可测）。
- `Sources/ConductorCore/Companion/SpriteAtlas.swift`
  - `struct SpriteAtlas { let rows=9, cols=8; func cell(for mood: PetMood, frame: Int) -> (row: Int, col: Int) }`——8×9 行映射 + 列回绕。
- `Sources/ConductorCore/Companion/BubbleCoalescer.swift`
  - `struct BubbleCoalescer { mutating func ingest(turnID: String?, text: String) -> BubbleState }`——同 turn 合并、跨 turn 换气泡。

新增测试 `Tests/ConductorCoreTests/Companion/`：

- `PetStateReducerTests`：每条 activity→mood；pending 打断 thinking；celebrate 瞬态时序 + 被 streaming 打断；静置→sleeping；优先级仲裁全覆盖。
- `SpriteAtlasTests`：每 mood→行；frame 越界回绕；边界。
- `BubbleCoalescerTests`：同 turn 合并 / 跨 turn 换 / 乱序 / 缺尾。

验证闸：`swift build` ✅ + `swift test` 全绿。

### M2 — `CompanionWindow` + `CompanionView`（显示，固定角落）

- `Sources/ConductorApp/Companion/CompanionWindow.swift`：`NSPanel` 透明浮层（对标 `ToastHUD.swift:52-62`，但 `ignoresMouseEvents=false`、去 `.transient`、`.nonactivatingPanel` 不抢焦点）；位置 `@AppStorage` 持久化 + 多屏 clamp。
- `Sources/ConductorApp/Companion/CompanionView.swift`：SwiftUI 精灵帧动画（`SpriteAtlas` 取帧）+ speech bubble，复用 `Theme`/`AppStyle`。
- `Sources/ConductorApp/Companion/CompanionController.swift`：`@MainActor ObservableObject`，订阅 `BuiltinAgentSession.$phase`/`$transcript` + `FeedCenter.$pending` → 映射 `AgentSignal` → `PetStateReducer` → `@Published mood/bubble`；持有 window。
- `AppCoordinator`：用**共享的** `BuiltinAgentSession` + `c.feedCenter` 造 `CompanionController`（守零分叉，注入同实例）。
- `Resources/Companion/`：放一张占位 8×9 图集先跑通管线。

验证闸：`swift build`；dev app 真跑，手动触发 streaming/审批/失败，**各心情截图**（独立 state dir，不碰用户实例）。

### M3 — 交互（输入 / 审批 / 跳转 / 开关）

- 点宠物冒输入框 → `session.prompt()`；气泡流式渲染（`BubbleCoalescer`）。
- `mood==.needsYou` 气泡内联 `允许/本会话允许/拒绝` → `feedCenter.resolve(id:decision:)`。
- 点本体 → 跳/聚焦内置 Agent 面板（面板未落则降级聚焦入口）。
- 命令面板（⌘K）+ menu bar + 设置开关；默认关。
- 文案 `L(...)` 中英；Esc 收起、⌘↵ 发送。

验证闸：`swift test` 全绿；dev app 真跑 + 一轮真 LLM「点宠物发问→流式→工具调用→needsYou→气泡批准→celebrating」端到端截图。

### M4 — 深度（Phase 2）

- 窗口当障碍物贴边溜达（`CGWindowListCopyWindowInfo`）；形状命中测试（alpha 裁，空白穿透）。
- `say` TTS 摘要播报（默认关，可选 system voice）。
- 多 session 轮显 / 叠气泡。
- `companion-state` socket query（`AutomationService.handle()`，纯可读）。
- 补 `THIRD_PARTY_NOTICES`（openpets / pet-therapy MIT）。

验证闸：socket query 单测 + 各深度项 dev app 截图。

### 里程碑验收口径

每个 M：`swift build` 通过 + `swift test` 全绿（含新测）+ 涉及 UI 的 dev app 真跑 + 截图。全功能收官＝M1-M4 全绿 + 真 LLM 端到端截图 + 能进 release notes。

---

参考实现：[openpets](https://github.com/alterhq/openpets)（状态→动画、8×9 atlas，MIT）、[pet-therapy](https://github.com/raman0c17/pet-therapy)（透明窗 + 帧动画 + 窗口障碍物，MIT）；底座见 [`builtin-agent-pi-plan.md`](builtin-agent-pi-plan.md)。现有可复用范式：`ToastHUD.swift`（透明 NSPanel）、`FeedPanelView.swift`（审批 UI + PanelWidth/Resize 挂载）、`FeedCenter.swift`（`pending`/`submit`/`resolve`）。

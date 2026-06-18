# GOAL：对标 cmux / Warp，把差距逐个补齐到商业化产品级

> 本文件是 **goal 模型的主控 runbook**，反复执行、可断点续做。
> **唯一目标来源**：[`docs/竞品差距调研-warp-cmux.md`](docs/竞品差距调研-warp-cmux.md)（逐功能差距清单）。
> **总目标**：把该文档里 conductor 落后 cmux（及选择性对标 Warp）的每一项，按下方「固定流程」逐个做到**稳定好用、商业化产品级**，直到所有 🔴/🟠 项翻 ✅。

---

## 核心打法：深度优先，不靠堆功能数量

**超越 cmux/Warp 不是"它有的我也加一个"，而是把每个功能当回事、扎到底**：想清楚**这个功能自己**真正需要的子功能、状态和交互，每个小交互都做足，让"好用度"碾压对手的"有这个功能"。**功能数量不是 KPI，每个功能的厚度与交互质量才是。**

**深度从功能自身长出来，不是套模板。** 每个功能有它自己的自然深度，别拿别的功能的维度生搬。看几个例子就懂"深度"长什么样、且各不相同：

- **Skills（管理可复用产物）** → 它自然长出：中心库、远程拉取+更新检测、全局级/项目级、预设、导入导出、diff、发现收编、审计。**这是因为它管的是"产物"，不是给别的功能照抄的清单。**
- **Feed 审批（实时决策）** → 它自然需要的是：把所有待批项收口成一个队列、审批策略与规则、inline 看清到底要批什么、超时默认动作、审计。**和"中心库"没关系。**
- **浏览器（操作网页）** → 它自然需要的是：登录态导入、脚本化/录制回放、截图归档、DevTools、多标签。

**第 3 步怎么找一个功能的深度**：从这个功能本身出发问——用户拿它会反复做哪些动作？有哪些状态/边界/失败？怎么少点几步就完成？哪里需要"看清楚再操作"？AI 怎么调它？把这些答全、做透，就是它的厚度。**适用什么做什么，不适用的根本不用提。**

---

## 每次运行怎么开始（给 goal 模型）

1. 打开下方「功能 backlog」，从上往下找**第一个状态不是 ✅ 的项**。
2. 对它执行下方「固定流程」**全部 7 步，不跳步**。
3. 做透、测过、验收通过后，把该项状态翻 ✅（写上验证方式与提交号），同步更新对标文档里对应行。
4. 取下一项，重复。**一次只做一个功能，做透再下一个，不并行半拉子。**

---

## 全局铁律（每个功能都适用，违反即不算完成）

1. **不要兼容，删就删**：替换半成品/做得差的实现时，直接删旧代码、删旧数据格式、删旧路径。**不留 feature flag、不留兼容垫片、不留迁移逻辑、不留"旧版本"分支。** state/config schema 想改就改。
2. **商业化产品级完成度**：每个功能按"**能放进产品截图、能写进 release notes、付费用户不会觉得是半成品**"的标准做，不是最小可用。稳定好用 > 功能多。
3. **穷尽式自测，硬要求**（不接受 smoke 充数）：
   - (a) 纯逻辑抽到 `ConductorCore`，新增/扩充单测，覆盖**正常 + 边界 + 异常**；`swift test` **必须全绿**才算完。
   - (b) `swift build` 必须通过。
   - (c) **真跑通 + 连 UI 一起验**：构建 dev app 启动，实际操作该功能，肉眼确认行为正确，**截图留证**。逻辑测试过了但 UI 没真跑过，不算完成。
4. **绝不动用户正在运行的 Conductor**（用户本机常开着一个正式实例）：
   - 测试一律用**独立构建**：`swift run ConductorApp` 或打包成**独立 bundle id / app 名**（如 `Conductor-Dev.app`，bundle id `dev.conductor.goal`）。
   - **严禁** `killall Conductor` / `pkill -f Conductor` / `pkill -f conductor`。只能 kill 自己这次启动的 dev 进程 **PID**（记录 PID，用 `kill <pid>`）。
   - dev 实例的 state/config 写**独立目录**（设 `CONDUCTOR_STATE_DIR`/独立 `HOME` 或临时目录），不要污染用户的 `~/.config/conductor`、`~/Library/Application Support/conductor`。
5. **口味铁律**：反感发闷的渐变/玻璃质感。用公认成熟配色（官方 hex），复用现有 `Theme` 系统的 accent/语义色。信息密度高、紧凑可扫读、达到截图门面级。
6. **对标真实现**：必要时回看本地 cmux 源码 `~/Desktop/_research/cmux`（及 `warp-themes` / `warp-workflows`）确认竞品的具体行为，不要凭印象。
7. **双接口原则（人 + AI 都好用）**：凡是用户能做的动作，**默认同时提供给 AI/脚本调用**——人走 GUI（鼠标 + 键盘 + 命令面板），AI 走 automation socket / CLI，**两条路径行为完全一致**。conductor 是 agent 工作台，"agent 能自己驱动 conductor" 本身就是差异化卖点。详见下方「设计与交互标准」。
8. **设计先行**：第 3 步必须先产出**交互设计说明**（覆盖下方 checklist），评审自检通过后再写第 4 步的代码。**不接受"边写边想交互"。**

---

## 设计与交互标准（硬门槛——第 3 步必须逐条产出并自检）

> 「设计要非常完善，交互是重点，人要好用、AI 也要好调用，按商业化产品来。」
> 每个功能在写代码前，先把下面四块写成一份「交互设计说明」（放进该功能的设计笔记 / PR 描述）。任何一条 N/A 也要写明为什么 N/A。

### ① 交互完整性（把所有状态都设计到，不留毛边）
- **全状态覆盖**：正常态、**空态**（无数据时给引导而非空白）、**加载态**、**错误态**（可读错误 + 重试路径）、**无权限/未配置态**（如 `gh` 未装、未登录）、**极端量**（50+ 工作区 / 超长分支名 / 几十个端口 → 截断 + 溢出收纳，不撑爆布局）。
- **反馈即时**：每个操作有即时视觉反馈；耗时操作有进度/转圈；破坏性操作有确认或可撤销。
- **可逆**：删除/重写类操作可撤销或二次确认，不让用户一键误删无救。

### ② 人好用（GUI 一等公民）
- **多入口可达且一致**：主要动作同时支持 **鼠标点击 + 键盘快捷键 + 命令面板（⌘K）搜索 + 右键菜单**（按场景取舍，但至少命令面板能搜到）。
- **键盘优先**：核心流程能全程不碰鼠标完成；新快捷键经 `KeyChord` 注册并做**冲突检测**，不与系统/现有键冲突。
- **可发现性**：用户不看文档也能找到并理解功能（命令面板可搜、空态有引导、图标/文案自解释）。
- **一致性**：复用现有 `Theme`（accent/语义色/间距/圆角/阴影）、现有组件与图标语言（SF Symbols），**不要每个功能自造一套视觉**。
- **本地化 + 无障碍**：中/英文案走 `L(...)`；动态字号不破版；控件有可访问性标签（至少不破坏 VoiceOver）；IME 输入正常。
- **性能即体验**：主线程不卡，列表滚动顺，**大数据量用虚拟化/截断/去抖**（侧栏元数据已按 15s/180s 节流，UI 侧再去抖）。

### ③ AI 好调用（机器接口一等公民）
- **动作可被 socket/CLI 触发**：该功能的用户动作，尽量在 automation socket / CLI 暴露对应命令（如：开浏览器、导航、发指令、读状态、**批准 Feed 请求**、建工作区/分屏）。对标 cmux `docs/cli-contract.md` 的覆盖广度。
- **稳定寻址**：用稳定的资源 id 或短引用（`workspace:N` / `pane:N` / `surface:N` 之类）定位对象，不靠易变的下标。
- **结构化 I/O**：输入/输出走 JSON；**可读取状态**（query）也要有，不只是触发动作（command）——AI 要能"看见"再"操作"。
- **明确错误**：失败返回明确错误码/信息，便于 agent 自处理与重试。
- **行为对齐**：socket/CLI 路径与 GUI 路径走同一套核心逻辑（同一个 reducer/服务），杜绝两边行为分叉。

### ④ 商业化打磨（产品门面）
- **截图门面级**：默认状态下界面就好看、信息密度合适、可直接进官网截图/release notes。
- **首次体验**：未配置时给清晰引导（怎么开/怎么连），而不是报错或空白。
- **文案专业**：无 TODO/占位/英文穿帮/调试串；错误文案给"下一步怎么办"。

---

## 固定流程（7 步，每个功能都这样跑）

| 步 | 名称 | 做什么 | 产出 |
|---|---|---|---|
| 1 | **定位现状** | 读对标文档该项 + 读 conductor 源码，判定：`无` / `半成品(数据有UI无之类)` / `做得差` / `已达标`。列出相关文件。 | 现状判定 + 文件清单 |
| 2 | **决策** | `无`→新建；`半成品`/`做得差`→**直接重写**（删旧实现，遵守铁律1）；`已达标`→标 ✅ 跳过。基准是「商业化产品该有的样子」。 | 决策（重写/新建/跳过） |
| 3a | **功能展开** | 从**这个功能本身**出发，列出它真正需要的子功能/状态/交互（见「核心打法」的找深度方法）。**不是套 Skills 的维度**——Skills 只是"认真做透一个功能"的例子。目标是那种厚度，不是那张清单。 | 这个功能自己的子功能树 |
| 3b | **交互设计** | 对每个子功能逐一产出「交互设计说明」（覆盖「设计与交互标准」四块 checklist）；抽**纯逻辑 seam** 放 `ConductorCore`（可单测）；UI 放 `ConductorApp`。对照 cmux/Skills 具体行为。遵守口味铁律。 | 逐子功能设计说明 |
| 4 | **实现** | 一次做透。删掉被替代的旧代码。稳定好用优先。 | 代码 |
| 5 | **测试** | 见铁律3 (a)(b)(c)：`swift test` 全绿 + `swift build` 过 + dev app 真跑 + UI 验 + 截图。 | 测试 + 截图 |
| 6 | **验收** | 对照该项「验收要点」逐条确认；性能（多工作区/多 pane 不卡主线程）；口味过关。 | 验收勾选 |
| 7 | **收尾** | 该功能**独立提交**（一个功能一个 commit）；本文件 backlog + 对标文档该行状态翻 ✅，写验证方式。 | commit + 状态更新 |

---

## 功能 backlog（来源对标文档 §2/§4，已排优先级）

> 状态：⬜ 未做 ｜ 🔄 进行中 ｜ ✅ 完成（翻 ✅ 时写：验证方式 + commit）
> 「现状」列是已核实的事实，goal 模型仍需在第 1 步复核。

### 🔴 P0 — 核心竞争力缺口

| # | 功能 | 现状（已核实） | 决策 | 验收要点 | 状态 |
|---|---|---|---|---|---|
> **原「侧栏状态指挥台」已移除**：现有侧栏 + tab/侧栏状态点（`thinkingPanes`/`unseenDonePanes`）+ 任务总览（⌘⇧M Mission Control）+ Agent Tools 窗，"一眼看全 agent 状态"本就够用，不重复造轮子。侧栏维持现状。

| # | 功能 | 现状（已核实） | 决策 | 验收要点 | 状态 |
|---|---|---|---|---|---|
| 1 | **Feed 内联审批** | **无内联审批**：agent 要权限/ExitPlan/提问时，目前只有"待处理提示"（`thinkingPanes`/`unseenDonePanes` 点），要批准还得跳进 pane 手敲。 | 新建 | agent 权限请求 / ExitPlan / AskUserQuestion 在 app 内用按钮直接处理（Once / Always / All tools / Deny）；带软超时与审计日志；**双接口**：socket 也能 list 待批项 + approve/deny。对标 cmux Feed（`~/Desktop/_research/cmux/docs/feed.md`）。 | 🟡 机制全通+全测，差真 claude 端到端手验 |

**Feed 进度**（拆切片做，每片独立 commit）：
- ✅ **底座**（`7b9ebe8`）：`ConductorCore/Feed` 纯逻辑——请求模型 + 策略/规则引擎（deny 压 allow、记忆规则、glob），12 测试。
- ✅ **socket 阻塞 gate**（`6ab061d`）：`FeedCenter`（submit 挂起 continuation / resolve / cancel / 超时 / 审计 / 策略持久化）+ `AutomationService` `feed-request` 异步阻塞 + `AppCoordinator` 接线，6 测试。
- ✅ **GUI 面板**（`6aab228` + 截图验证 `006fe05`）：右侧审批面板，命令/计划 monospace 展示、allow 实心/deny 红描边分级按钮、自动弹出、命令面板可开；离屏渲染回归测试 + 截图肉眼核对。
- ✅ **双接口 + 审计**（含于 gate）：socket `feed-list / feed-approve / feed-deny / feed-answer`；审计环形缓冲。
- ✅ **hook 安装**（`86eea49`）：`conductor-approve`（python3）读 Claude PreToolUse、经 `$CONDUCTOR_SOCKET` 调 `feed-request` 阻塞拿决策、按 hook 契约 allow/deny；fail-open；`FeedActionCategory.infer` 服务端推断类别。类别推断 3 测 + 脚本端到端 4 测（真 socket server + 真跑脚本）。
- ✅ **UI 开关**（`58915e6`）：CLI 工具面板「工具审批」卡，启用/停用 hook。
- 🟡 **真 claude 端到端**：脚本↔socket↔决策、submit↔resolve 两半都已稳定测过（28 个 Feed 测试），GUI 已截图验证。**整条链路的真 claude 闭环受环境限制未跑**——用户实例占着自动化 socket（双开保护），不碰它；需手动在无其它实例时启用「工具审批」+ 跑 claude 验证。（曾写脚本→真 FeedCenter 的全链路集成测试，因 process+socket+continuation 时序易挂、违背"稳定"原则已撤。）
| 2 | **内置浏览器 pane + 可脚本化浏览器 API** | **完全无**。可复用资产：`SweetCookieKit` 已能导入 Chrome/Safari/Gecko cookie（做开箱登录态）。 | 新建 | WKWebView 分屏 pane；地址栏/omnibar、前进后退/刷新/缩放/页内查找/DevTools；cookie 导入登录态；CLI 自动化（navigate/click/fill/type/eval/wait/screenshot/snapshot），对标 cmux `docs/agent-browser-port-spec.md`。**体量大，可拆多个 commit，但每个 commit 都要稳定可测。** | ⬜ |

**P0 旁的快速清理（先做，省电）**：`WorkspaceMetadataCenter` 里 **lsof 端口扫描（每 15s）+ `gh` PR 扫描（每 180s 起 subprocess）的产出 `.ports`/`.pullRequests` 全 Sources 零消费**（GUI 没读、socket 也没读）——纯耗电空转，**删掉这两个扫描器及相关字段/Timer**。`status / progress / log` 是 `AutomationService` 的 socket 接口（agent 在用），**保留**。 ✅ **已完成**（commit `afa8263`；验证：grep 零引用 + `swift build` 通过 + 390 测试全绿，含新增 `WorkspaceMetadataCenterTests` 8 例）。

#### P0 子功能树（从功能自身出发，不是套 Skills 的维度）

> 示范"做透"长什么样：每条都是 **Feed/浏览器各自真正需要的**，不是从 Skills 照搬的格子。

**① Feed 内联审批**（核心：人/AI 在 app 里就地决策，不用跳 pane 手敲）
- **统一待批队列**：所有 agent 的权限请求 / ExitPlan / AskUserQuestion 收口成一个队列，一处看全、逐条处理。
- **看清楚再批**：inline 展开到底批的是什么——命令实际内容（X-ray 式拆解）、ExitPlan 的计划、问题的选项，不让人盲批。
- **批准粒度**：Once / Always（这条）/ All（这类工具）/ Deny；同类可批量。
- **审批策略与规则**：per-工具 × per-动作（读文件/写文件/执行命令/网络…）默认策略 + allow/deny 规则（正则/命令匹配自动放行或拦截，deny 覆盖一切）。对标 Warp agent profiles + cmux Feed。
- **超时默认动作**：无人理 N 秒后的默认行为可配。
- **审计/历史**：每次批准/拒绝留痕（哪个 agent、批了什么、用了哪条规则），可回看。
- **多 agent 适配**：识别各 agent（claude/codex/…）的请求格式（对标 cmux 多 agent hook 桥）。
- **双接口**：socket `feed list` / `feed approve <id> --scope once|always|all` / `feed deny`，脚本也能批；与 GUI 同一套核心逻辑。

**② 内置浏览器 + 可脚本化浏览器 API**（核心：人能用、agent 能脚本驱动同一个浏览器）
- **基础 GUI（人好用）**：分屏 pane、地址栏/omnibar、前进后退/刷新/缩放、页内查找、DevTools、多标签、OAuth 弹窗。
- **开箱登录态**：导入 Chrome/Safari/Firefox/Arc/Edge… 的 cookie/历史（复用 `SweetCookieKit`，对标 cmux 浏览器配置导入），打开就是登录态。
- **可脚本化（AI 好调用）**：完整 CLI——navigate/click/fill/type/eval/wait/screenshot/snapshot（无障碍树 + 元素 ref），对标 `docs/agent-browser-port-spec.md`；人点 GUI 与 agent 跑 CLI 走同一套。
- **录制 / 回放**：录用户操作生成可复用脚本。
- **截图 / 快照归档**：自动化过程留痕，便于 agent 自验、人复查。

> 对比看：Feed 自然没有"中心库/远程拉取"，浏览器自然没有"全局级/项目级策略表"——**每个功能只长它自己需要的东西。**

### 🟠 P1 — 明显短板

| # | 功能 | 现状（已核实/推断） | 决策 | 验收要点 | 状态 |
|---|---|---|---|---|---|
| 4 | **Agent hibernation** | 无；已有 thinking/idle 判定（`AppCoordinator` 输出空闲检测）可复用。 | 新建 | 闲置后台 agent pane 自动挂起释放内存（杀进程），回到该 tab 自动按 resume 命令恢复；可配 idle 秒数 / 最多保活终端数。 | ⬜ |
| 5 | **工作区分组 + 竖向 tab + 多窗口** | 无分组（侧栏平铺）；横向 tab；仅独立工具窗，主终端无多窗口。 | 新建/重写 | 可折叠命名分组（配色/图标/pin/anchor/拖入）；竖向 tab 侧栏；主终端多窗口 + 工作区跨窗口拖动。分组/排序/折叠模型抽纯逻辑单测。 | ⬜ |
| 6 | **diff viewer + worktree 隔离 + PR 徽标** | 无 diff viewer / 无 worktree 隔离；PR 数据已在 metadata center（徽标随 #1 落地）。 | 新建 | 查看代码 diff、行内评论、附给 agent；每 agent 独立 git worktree/分支；侧栏 PR 徽标（随 #1）。 | ⬜ |
| 7 | **SSH 远程工作区** | 完全无。 | 新建 | `ssh user@host` 起远程工作区 pane；断线重连不丢；文件侧栏跟随远端根。**先做 SSH，云 VM 暂缓。** | ⬜ |
| 8 | **CLI 命令覆盖面 + 事件流** | automation socket 仅基础动作；无文档化事件流。 | 重写/扩展 | CLI 能完全驱动 UI（建工作区/分屏/发按键/读屏/设状态进度/订阅事件）；可重连、分类、JSONL 审计的事件流。对标 cmux `docs/cli-contract.md` / `docs/events.md`。 | ⬜ |
| 9 | **更广 agent 续聊/hook + AI 自动命名** | 续聊主要 Claude/Codex。 | 重写/扩展 | 借 cmux `vault.agents[]` 通用注册（声明探测进程 / session-id 来源 / resume 命令），覆盖更多 agent；工作区/标签按对话内容 AI 自动命名（手动名优先）。 | ⬜ |
| 10 | **Markdown 查看器** | 无（仅 skill 描述渲染）。 | 新建 | `.md` 渲染面板 + 文件变更实时重载 + 字号/缩放（Mermaid 可选）。 | ⬜ |

### 🟢 P2 — 锦上添花

| # | 功能 | 决策 | 验收要点 | 状态 |
|---|---|---|---|---|
| 11 | 图片粘贴/文件拖入终端 + OSC8 点击打开 + vi copy mode | 新建 | 截图可粘进终端喂 agent；OSC8 链接可点开；键盘 copy mode。 | ⬜ |
| 12 | 富文件预览面板（图片/PDF/QuickLook/媒体） | 新建 | 侧栏点文件直接预览。 | ⬜ |
| 13 | 复用 ghostty 主题生态 + 主题选择器 + 背景图/模糊 + 行高/连字 | 重写 | 直接吃 `~/.config/ghostty` 主题/字体；实时主题选择器。 | ⬜ |
| 14 | 键位预设模板 / `when` 条件键位 / 设置同步 | 新建 | Tmux/Vim/iTerm 预设一键套；上下文条件键位。 | ⬜ |
| 15 | 通知声音 / 勿扰尊重 / OSC 9·99·777 / pane 蓝环 | 新建 | 不依赖 hook 也能感知 agent 状态；pane 蓝环。 | ⬜ |
| 16 | 项目级目录动作 `.cmux/actions` + 应用内 MCP OAuth | 新建 | 项目专属命令进命令面板（信任门）；托管 MCP 一键 OAuth。 | ⬜ |

### ⚪ 暂不做（设计取向不同，排在 P0/P1 之后，按产品野心再议）
Warp block 范式 · 自研补全/纠错/autosuggest（交给 shell）· 自研 agent/planning/voice（conductor 是编排器不自研 agent）· 内置代码编辑器+LSP · 完整团队/SSO/Drive · iOS/跨设备。

---

## 完成定义（整个 GOAL 收官）

- backlog 中所有 🔴 P0 + 🟠 P1 项状态 = ✅，且各自满足铁律3（`swift test` 全绿 + UI 真验 + 截图）。
- 对标文档 `docs/竞品差距调研-warp-cmux.md` 与本文件 backlog 状态同步一致。
- 全程未触碰用户正在运行的 Conductor 实例。

---

## 已知勘误（写给执行者，复核现状时注意）

- `WorkspaceMetadataCenter` 拆两半看：① `status/progress/log` **在用**——是 `AutomationService` 的 socket 接口（agent 写、可读回），**保留**；② `ports`（lsof/15s）+ `pullRequests`（gh/180s）**全 Sources 零消费**，纯空转，**删**（见「P0 旁的快速清理」）。
- "一眼看全 agent 状态"**不需要新建侧栏指挥台**——已由 tab/侧栏状态点 + Mission Control（⌘⇧M）+ Agent Tools 窗覆盖。对标文档 §A 的"tab 富信息"行可据此理解：缺的不是"看状态"，而是 git/端口/PR 这类**附加信息的展示**，且优先级低（P2，按需再做）。

# UI 生产化整改计划

> 目标：把若干「demo 感 / 假功能 / 泄露实现细节」的地方收敛成真实、可信的产品 UI。
> 原则：**不展示用户不能消费的开关；不把开发态 TODO / 实现细节摆到主视觉层；默认数据要么真实可用、要么留空引导。**
> 下列每条均已对照源码核实（附 `文件:行号` 证据）。

## 当前进度

- 已完成：#1 假开关移除、#2 provider 兜底文案、#3 停止自动落地 Snippet 示例、#4 共创入口降权、#5 Hook / 通知默认文案收敛、#6 空工作区欢迎态、#8 CLI 未配置渠道合并入口、#9 Skills 右侧面板首批承载收敛。
- 已部分完成：#7 Skill / Agent 拆出独立工具分段、#10 基础组件迁移推进中、#11 Mission Control / Queue 常驻教学文案降噪。
- 构建质量：`TerminalSurface` / `SessionRegistry` 收到主线程语义；稳定 ID 与工作区元数据类型补 `Sendable`，清理本轮 Swift 6 actor/sendable warning。
- 待单独设计：#7 Skill / Agent 底层组件拆分、#9 其它右侧面板承载规则、#10 剩余功能页组件迁移。

---

## P0 · 高优先级（影响可信度，必须改）

### 1. 假开关：`webExtras` / `batterySaver` 只写不读

- **问题**：用户能点、能存，但运行时**没有任何代码读取**，点了等于没点 —— 典型「假功能」。
- **证据**：
  - `Sources/ConductorApp/UI/UsageProvidersSettingsView.swift:1461`（`webExtras`）、`:1466`（`batterySaver`）—— 仅作为 toggle 写入 `flags`。
  - 全仓 grep：这两个 key **没有任何读取方**。
  - 对照：`historyTracking` 被 `CLIToolsView.swift:685` 读取、`avoidKeychainPrompts` 被 `UsageCredentials.swift:143` 读取 —— 这两个是**真**开关，保留。
- **方案（二选一）**：
  - **A（推荐，最快）**：直接删除 `webExtras` / `batterySaver` 两个 toggle 描述符（`UsageProvidersSettingsView.swift:1458–1471` 的 codex 分支）。codex 当前无 provider 专属开关，就不显示「选项」区。
  - **B**：若确实想要「省电/保守刷新」，把它接到真实行为（如后台刷新间隔 / 并发节流），再保留开关。工作量大，非必要不做。
- **验收**：codex 详情页不再出现这两个开关；或开关变动能在行为上观测到（刷新节奏变化）。

### 2. 开发态兜底文案暴露给用户

- **问题**：`credentialHint` / `setupHint` 的 `else` 分支文案像没写完的 TODO。
- **证据**：
  - `UsageProvidersSettingsView.swift:1549` → `「该 provider 暂无额外配置项。」`
  - `UsageProvidersSettingsView.swift:1563` → `「需要补充该 provider 的凭证检测方式。」`
- **方案**：把兜底改成面向用户的中性表述，并明确「自动检测 / 手动」语义：
  - 1549 → `「该渠道无需额外配置，检测到登录态即自动显示用量。」`
  - 1563 → `「该渠道通过本机登录态自动检测，无法自动获取时用量留空。」`
- **附带**：审一遍这两个函数所有分支，确保没有第二处「需要补充 / 待定 / TODO」式措辞。
- **验收**：任意 provider 详情页文案都不含「需要补充 / 暂无 / 待定」之类开发口吻。

---

## P1 · 中优先级（信息架构 / 默认数据）

### 3. 默认 Snippets 是示例数据（含危险命令）

- **问题**：首次使用直接塞三条 Git 片段，其中 `git add -A && git commit -m ""` 是空提交信息、会一键提交全部改动 —— 既像 demo starter，又有误操作风险。
- **证据**：`Sources/ConductorApp/SnippetStore.swift:106–113`（`starterPack`）。
- **方案**：
  - 首次使用改为**空状态 + 引导**（「还没有片段，点 + 新建，或从模板导入」）。
  - 把现有三条挪进一个**模板库**，用户主动「添加」。
  - 至少先移除 `git add -A && git commit -m ""`（空 message 危险），保留只读的 `git status` / `git log` 作为示例可接受。
- **验收**：全新用户看到的是空状态或可选模板，而非自动落地的可执行命令。

### 4. 「共创计划」占了顶栏强入口

- **问题**：整页是「去提一条 / 看仓库 / 最近在琢磨的方向」，更像 landing page / roadmap；虽然不在面板分段 tab 里，但顶栏仍有强入口。
- **证据**：`CoCreateView.swift:42` 起；`TabBarView.swift:91` 顶栏按钮打开 `.coCreate`；`ToolsPanelView.swift:129` 负责渲染页面。
- **方案**：从顶栏强入口移除，迁到 **关于 / 帮助** 或设置底部一个低调入口（「反馈 / 共创」）。保留功能，降权展示。
- **验收**：顶栏只保留高频工作入口；共创入口在帮助/关于里可达。

### 5. Hook / 通知 UI 泄露实现细节

- **问题**：把路径和环境变量当作正文摆给用户。用户要的是「状态 + 一键修复」，不是实现说明。
- **证据**：
  - `HooksManagerView.swift:200` —— 正文讲 `~/.claude/settings.json`、`~/.codex/hooks.json`、`$CONDUCTOR_PANE_ID`。
  - `CLIToolsView.swift:507` —— 把「ad-hoc 签名」原理塞进 `help`。
- **方案**：
  - 主文案收敛为状态 + 动作：`「已为 Claude / Codex 安装完成提醒（仅对 Conductor 启动的会话生效）」` + `[安装] / [移除]` 按钮。
  - 把路径 / `$CONDUCTOR_PANE_ID` / ad-hoc 原理移到「详情」展开或 `?` tooltip，默认折叠。
- **已落地**：Hook 市场不再把日志路径写进正文；配置入口显示为 Claude/Codex 配置而非具体文件路径；已配置 hook 默认展示来源、托管状态和动作摘要，命令仅在展开后显示；recipe hover 不再暴露 shell 命令；用量、快捷键、CLI 状态和会话删除确认里的路径/PATH/config 等实现层表达已改成用户层文案。
- **验收**：默认视图无文件路径 / 环境变量；展开「详情」才看到。

### 6. 空工作区欢迎态偏演示

- **问题**：空 workspace 直接盖一张插画启动面板，好看但「新品 demo」味重。
- **证据**：`RootView.swift:29`（`QuickStartLaunchPanel`）。
- **方案**：欢迎态优先放**真实操作**：最近工作区、恢复上次会话、新建/导入项目；插画弱化为背景或留白。
- **验收**：空状态首屏第一眼是可操作的真实入口，而非纯插画 + 口号。

### 7. Skills 页里混着 Agents

- **问题**：Skills Manager 的 quick bar / tab 同时管 `skills.sh` 与 `Agents`，信息架构未定型。
- **证据**：`SkillsManagerView.swift:167/195`、`552/559`、`616/637`（`skills.sh` 与 `Agents` 并列）。
- **方案**：Skill 与 Agent 拆成两个并列入口（可共用列表/卡片组件风格），Agent 不再藏在 Skill 页内部 tab 里。先拆视图层级，再统一组件样式。
- **验收**：Skill 管理与 Agent 管理是两个清晰入口；各自页面不互相嵌套对方的 tab。

### 8. 渠道列表密度过高

- **问题**：CLI / 用量区域把大量未配置 provider 作为 rows 平铺，右侧面板空间一小就像 demo catalog。
- **证据**：`CLIToolsView.swift:584–609`（`其它渠道（未配置）` 直接 `ForEach(inactive)`）。
- **方案**：已配置/有状态的渠道常驻展示；未配置渠道收进「添加渠道」入口，进入后用搜索 + 分类 + 推荐项选择，不在主面板平铺全部 provider。
- **已落地**：未配置渠道已收进「添加渠道」；Provider 详情把本机登录、浏览器登录、API key 等用户任务语言放在主层，具体文件/环境注入等实现细节不再做主文案；CLI 检测的 PATH 说明移入 hover。
- **验收**：默认视图只展示用户正在使用或需要处理的渠道；未配置 provider 通过添加流程可达。

### 9. 右侧面板承载规则缺失

- **问题**：右侧面板被当完整页面使用，Mission Control、Skills、Deploy、Provider、Hook 等都倾向堆在同一屏，容易撑爆。
- **证据**：`SkillsManagerView.swift` 单文件超过 6000 行，且同页承载 discovered / installed / deploy / agents / market 等多种任务。
- **方案**：右侧面板只承载当前任务的核心路径；二级信息进入折叠区、详情抽屉或独立弹层。默认布局优先「列表 + 详情」，少用横向并列大卡。
- **已落地（Skills 首批）**：工作台顶部从横向按钮条改为「一个主行动 + 自适应次级行动」；选中 Skill 的部署、就绪检查和来源状态改成按需露出，健康项不再常驻占位；Skill / Preset / Project 展开区移除硬分割线，改为一体化 soft group。
- **已落地（Skills 重构首批）**：主导航收敛为 `Library / Deploy / Discover / Maintain`；普通 Skills 页不再把 Agents、Preset、项目、活动作为同级大入口混排；Library 改为稳定列表 + 选中行轻详情，不再默认进入 command/cockpit 式首屏。
- **已落地（Skills 详情降噪）**：二级详情移除 `Pipeline`、评分圆环、Rail Stat 和大指标 tile；Overview 改为下一步建议、属性、就绪检查和来源状态面板。
- **已落地（浮层补充）**：Queue、Activity Center、Blocked Inbox、Mission Control 去掉 header/content 之间的硬分割线，改由内边距、soft group 和空态组件建立层次。
- **验收**：窄面板下无横向溢出；首屏只出现一个主任务和一个辅助状态区。

### 10. 基础组件统一不足

- **问题**：按钮、状态 badge、卡片、tooltip、空状态在不同模块里各写各的，导致同一种动作看起来像不同产品。
- **证据**：`CLIToolsView.swift`、`SkillsManagerView.swift`、`HooksManagerView.swift` 内均有局部 button/card/badge 实现。
- **方案**：抽出统一的 `ToolIconButton` / `ToolActionButton` / `StatusBadge` / `EmptyState` / `InlineHelp`，禁止功能页重复造基础组件。
- **已落地**：新增 `ToolBadge` / `ToolActionButton` / `ToolEmptyState` / `ToolStatusLine` / `ToolSoftGroup`，并迁移 CLI、Hook、Skills、Provider、Snippets、Settings、Queue、Activity Center 的一批状态与动作控件；Skills 自造图标按钮已改为复用全局 `IconOnlyButton`；Queue 面板移除硬分割线，CLI / Provider / Settings 的显性动作与状态 pill 继续收口到基础组件。
- **验收**：图标按钮都有 hover help；文字按钮、危险按钮、次级按钮、状态 badge 的视觉语言一致。

---

## P2 · 低优先级（文案降噪）

### 11. 主视觉层教学文案过多

- **问题**：操作说明直接印在主区域，长期使用是噪音。
- **证据**：
  - `MissionControlPanel.swift:29` → `「点卡片直达 · Esc 关闭」`
  - `QueuePanel.swift:50` → `「回车加入队列；当前任务完成（Stop）后自动逐条发出」`
- **方案**：改为 **placeholder / tooltip / 首次出现的一次性提示**；快捷键提示用 `⌅ / Esc` 角标而非整句说明。
- **验收**：主区域不常驻整句操作说明；新手提示走 placeholder 或可关闭的一次性气泡。

---

## 建议执行顺序

1. **P0 一把过**（同一文件 `UsageProvidersSettingsView.swift`）：删假开关（#1）+ 改兜底文案（#2）。改动小、收益最高，先发一版。
2. **P1 按文件分批**：#3 Snippets、#5 Hook/通知文案、#6 空状态、#8 渠道列表密度 —— 各自独立、互不依赖，可并行。
3. **#4 共创降权 / #7 Skills·Agents 拆分 / #9 右侧面板规则 / #10 基础组件统一** 涉及信息架构和组件边界，单独评审后再动。
4. **P2 文案降噪**最后扫一遍，连带审查其它面板是否有同类常驻教学文案。

## 验收总则

- 全仓 grep 不再有「只写不读」的 `flags` key（可加一条简单的「开关必须有读取方」自查）。
- 用户可见文案无「需要补充 / TODO / 暂无 / 待定」开发口吻。
- 默认落地的数据要么真实可用、要么留空引导，不出现可一键执行的示例破坏性命令。
- 文件路径 / 环境变量 / 签名原理等实现细节默认不在主视觉层。
- 右侧面板默认不平铺低优先级 catalog；复杂信息通过搜索、折叠、抽屉或详情页逐步展开。
- 基础操作组件统一复用，图标按钮必须提供 hover help。

## Skills 重做方向

- **视觉基调**：安静、专业、高密度；不再把 `Cockpit` / `Pipeline` / 大仪表盘当主路径。
- **Library**：日常管理入口。稳定行高、轻详情、批量选择；只展示名称、描述、来源、同步目标、健康状态。
- **Deploy**：分发入口。Preset 和项目工作区合并到部署语境，后续再演进为 Skill × Agent/Project 矩阵。
- **Discover**：添加入口。skills.sh、本地导入、Git、扫描本机统一放这里。
- **Maintain**：维护入口。来源异常、更新、Activity 收成维护队列。
- **后续**：继续拆小 `SkillsManagerView.swift`，把 Library / Deploy / Discover / Maintain 分文件，并把 Deploy 演进为真正的 Skill × Agent/Project 矩阵。

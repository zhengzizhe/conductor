# Conductor 竞品差距调研:对比 Warp 与 cmux（细到每个小功能）

> 调研日期：2026-06-16
> 对象：**Conductor**（我们，本仓库）vs **cmux**（manaflow-ai/cmux）vs **Warp**（warp.dev）
> 目的：逐功能域、细到每个小功能地盘点 conductor 相对两个竞品缺什么，并给出优先级。

---

## 0. 来源与可信度说明（先把底交代清楚）

| 对象 | 数据来源 | 可信度 |
|---|---|---|
| **Conductor** | 本仓库 `Sources/` 全量源码 + README + 实锤 grep | ★★★★★ 源码直读 |
| **cmux** | `git clone manaflow-ai/cmux` 全量源码（Swift app + web + daemon + workers + CLI + docs + skills + CHANGELOG，247MB） | ★★★★★ 源码直读 |
| **Warp** | **核心闭源**。基于：① 官方文档 docs.warp.dev / warp.dev / blog（联网抓取）；② 两个开源仓库 `warpdotdev/themes`（535 个主题，验证 YAML schema）和 `warpdotdev/workflows`（269 个 workflow + FORMAT.md + Rust 类型定义） | ★★★☆☆ 文档+开源外围，非核心源码 |

**关键定位差异**（理解差距前必须先认清）：

- **Conductor 与 cmux 是同源正面竞品**：都是 macOS 原生 Swift + libghostty(Ghostty) 真终端，都定位"给 AI coding agent 用的多 pane 终端工作台"，都**不是聊天壳、不自研 agent**，而是把 `claude` / `codex` 等外部 CLI 包进真终端里。→ **cmux 是最该逐项对标的对象。**
- **Warp 是另一条路线**：Rust 自研 GPU 终端 + 自研 Agent（代号 Oz）+ Warp Drive + Warp Code，是"Agentic Development Environment"。它的很多 AI 原生能力（block、自研补全、自研 agent、Drive）跟 conductor「不自研 agent、保持真终端」的设计哲学冲突，**不能无脑抄**，只能选择性借鉴。下文用 ⚪ 标注这类"设计取向不同"的项。

**图例**
- 功能对比：✅ 有 ｜ 🟡 部分/弱 ｜ ❌ 无
- 缺口优先级：🔴 **P0**（核心竞争力缺口，建议尽快补）｜🟠 **P1**（明显短板）｜🟢 **P2**（锦上添花）｜⚪（设计取向不同，选择性借鉴）

---

## 1. 总体结论

**一句话**：conductor 在「**多 provider 用量/成本统计**」「**跨工具的 Skills/Hooks/MCP 管理**」上**领先两个竞品**；但在「**内置浏览器 + 可脚本化浏览器**」「**SSH/远程/云沙箱**」「**iOS/跨设备**」「**Agent 编排成熟度（hibernation / 自动命名 / Feed 审批 / teams）**」「**diff/markdown/文件预览查看器**」「**侧栏富信息（git/PR/端口）+ 工作区分组 + 多窗口**」上，被 cmux 系统性甩开。Warp 的差距更多在"它走了自研 agent + Drive 路线"，属于另一维度。

**差距数量速览（粗略）**

| 维度 | conductor 相对 cmux | conductor 相对 Warp |
|---|---|---|
| 终端/分屏/窗口基础 | 落后约 30%（缺竖 tab、分组、多窗口、canvas） | 落后（缺 block、自研补全、vim 输入） |
| Agent 编排 | 落后约 50%（缺 hibernation、auto-naming、Feed、teams、events 流） | 落后很多（Warp 自研 agent 整套） |
| 浏览器 | **落后 100%（完全没有）** | 落后（Warp 无内置浏览器，反而 conductor=cmux 同样视角看 Warp 也没有） |
| 远程/云 | **落后 100%（完全没有 SSH/VM/远程 daemon）** | 落后（Warp 有 cloud agents / SSH 扩展） |
| 移动端/跨设备 | **落后 100%** | 落后（Warp 有 web/手机操控 session） |
| 查看器（diff/md/文件预览） | 落后 100% | 落后（Warp 有 Code review/编辑器/LSP） |
| 用量/成本统计 | **领先**（conductor 48 providers，cmux 只有云 VM 计费） | **领先**（Warp 只统计自己的 credit） |
| Skills/Hooks/MCP 管理 | **领先/持平**（conductor 跨工具统一管理 UI） | 持平（各有侧重） |

---

## 2. 逐域差距分析

### A. 窗口 / Tab / 分屏 / Pane

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 水平/竖直分屏 | ✅ ⌘D/⌘⇧D | ✅ | ✅ CMD-D/⇧CMD-D |
| 分屏树任意嵌套 | ✅ SplitNode 二叉树 | ✅ | ✅ |
| 拖分隔条调比例 | ✅ | ✅ | ✅ |
| 均分 split | ✅ ⌘⌃E | ✅ ⌃⌘= | — |
| pane 缩放/最大化 | ✅ ⌘↵ | ✅ ⌘⇧↵ | ✅ ⌘⇧↵ |
| ⌘+拖动重排 pane | ✅ | ✅（拖到别 split / 别窗口） | ✅ 拖动重排 |
| 方向键切焦点 | ✅ ⌘⌥方向 | ✅ ⌘⌥方向 | ✅ ⌥⌘方向 |
| 横向 tab | ✅ | ✅ | ✅ |
| **竖向 tab 侧栏** | ❌ | ✅ VerticalTabsSidebar | ✅ Vertical Tabs |
| **tab 富信息**（git 分支 / PR 号+状态 / 监听端口 / 最新通知文本） | 🟡 **数据层已实现**（`WorkspaceMetadataCenter`：lsof 端口 + `gh` PR + status/progress），但**侧栏 UI 未渲染**（半成品，见 GOAL.md #1） | ✅ 全有 | 🟡（vertical tab 有元数据） |
| **工作区分组**（可折叠、配色/图标、pin、anchor、拖入分组） | ❌ | ✅ workspace groups（⌘⇧G + CLI + per-cwd 配置） | 🟡（tab 配色 8 色） |
| **多窗口**（主终端开多个窗口） | ❌（仅独立 Agent Tools 工具窗） | ✅ ⌘⇧N + 工作区跨窗口拖动 + 多显示器 | ✅ ⌘⇧N |
| tab 重新打开（恢复关闭） | ✅ ⌘⇧T（栈深 10） | ✅ ⌘⇧T | ✅ ⇧⌘T（≤60s） |
| tab 配色 | ❌ | ✅ per-workspace 颜色 | ✅ 8 色 |
| tab 重命名 | 🟡（菜单/会话名） | ✅ ⌘R 内联 | ✅ 双击 |
| **freeform 画布布局**（2D 自由摆放 pane + 概览/minimap/对齐分布） | ❌ | 🟡 实验性 Canvas（⌃⌘C 一整套对齐/缩放/概览快捷键） | — |
| pane dimming（非焦点变暗） | ❌ | ❌ | ✅ |
| **同步输入广播**（一次输入打到多个 pane） | ❌ | ❌ | ✅ ⌥⌘I |
| 全局热键 show/hide 窗口 | ❌ | ✅ ⌃⌥⌘. | ✅ Global Hotkey |
| 菜单栏 extra（未读角标 + 快捷菜单） | ❌ | ✅ MenuBarExtra | — |
| Dock 角标未读数 | ✅ | ✅ | — |
| AppleScript 脚本化（.sdef） | ❌（只有自研 socket） | ✅ cmux.sdef（new window/tab/split/focus/input/query） | ✅ URI scheme |

**conductor 缺什么（细）**：
- 🟠 **竖向 tab 侧栏**——agent 多了横向 tab 放不下，cmux/Warp 都用竖排。
- 🔴 **侧栏/标签富信息**：每个工作区/tab 旁显示 **git 当前分支、关联 PR 编号+合并状态、进程监听的端口、最新一条通知文本**。cmux 全有，这是它"一眼看全部 agent 状态"的核心体验。conductor 侧栏目前只有 cwd / pane 数 / 最近会话。
- 🟠 **工作区分组**：可折叠命名分组、每组配色/图标/独立"+"按钮、pin、anchor 工作区、拖动入组、按 cwd 在配置里持久化分组规则。
- 🟠 **主终端多窗口** + 工作区跨窗口拖动 + 多显示器分配（`window display`）。
- 🟢 freeform canvas 画布布局（cmux 自己也还是实验性）。
- 🟢 同步输入广播 / pane dimming / 全局热键 / 菜单栏 extra / AppleScript 脚本化。

---

### B. 终端核心（渲染 / scrollback / 搜索 / copy mode / 链接 / 图像 / shell 集成）

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| GPU 渲染真终端 | ✅ libghostty Metal | ✅ libghostty Metal | ✅ Rust 自研 wgpu/Metal |
| PTY | ✅ | ✅ | ✅ |
| scrollback 容量 | ✅ 6 万–100 万行可配 + 裁剪器 | ✅ | ✅ |
| 终端内搜索 | ✅ ⌘F/⌘G/⌘⇧G/⌘E | ✅ ⌘F + find-in-directory ⌘⇧F | ✅ block 内 find |
| copy-on-select | ✅ | ✅ | ✅ |
| **vi copy mode**（键盘选择/复制） | ❌ | ✅ ⌘⇧M | ✅（编辑器级） |
| OSC 8 超链接 | 🟡 仅 hover 显示，**未实现点击打开** | ✅ OSC 8/11 | ✅ |
| **粘贴板图片粘贴进终端** | ❌ | ✅ clipboard image paste | ✅ images as context |
| **拖文件进终端**（本地/远程 scp 上传） | ❌ | ✅ FileDrop + 远程 scp 上传 | — |
| CJK 输入法 | 🟡（依赖 ghostty） | ✅ 专门 IME 合成处理 | ✅ |
| 读取现有 `~/.config/ghostty/config` | 🟡（有 ghostty overrides，但不直接复用用户主题/字体） | ✅ 直接读，复用主题/字体/色 | — |
| **block（命令+输出分组）** | ❌ | ❌ | ✅ Warp 核心范式 |
| 背景模糊/透明 | 🟡（主题里有 panel material） | ✅ background-opacity/blur | ✅ |
| 清屏 | ✅ | ✅ ⌘K | ✅ ⌘K |
| 导出 pane 文本 | ✅ NSSavePanel | ✅ capture-pane | ✅ block 复制 |

**conductor 缺什么（细）**：
- 🟠 **vi/键盘 copy mode**（不用鼠标选择复制）。
- 🟠 **OSC 8 链接点击打开**（现在只 hover 显示 URL，不能点）。
- 🟠 **图片粘贴 / 文件拖入终端**（agent 时代常要把截图喂给 claude/codex；conductor 现在做不到）。
- 🟢 **直接复用用户的 ghostty 配置/主题**（cmux 读 `~/.config/ghostty/config`，用户已有的字体/主题/色直接生效；conductor 只支持 ghostty overrides 键值）。
- ⚪ block 范式是 Warp 独有，且与"真终端"哲学冲突，**不建议做**。

---

### C. 会话恢复与续聊

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 启动恢复窗口/tab/pane 布局+cwd | ✅ restoreLayoutOnLaunch | ✅ | ✅ |
| 恢复 scrollback 内容 | ✅（裁到 4K 行） | ✅ best-effort | ✅ |
| 记录并续聊 claude/codex 会话 | ✅ 自动预填 `--resume`/`resume` | ✅ 同 + 15 种 agent | ✅ 云同步对话 |
| auto-resume 开关 | ✅ | ✅ terminal.autoResumeAgentSessions | — |
| 通用 surface resume 绑定（tmux/自定义 shell） | ✅ SurfaceResumeBinding + 信任模型 | ✅ surface resume set/show/clear | — |
| 误关恢复 | ✅ ⌘⇧T | ✅ ⌘⇧T + 浏览器面板 | ✅ ⇧⌘T |
| 会话目录定位/transcript 解析 | ✅ AgentSessionCatalog/Locator/Preview | ✅ | ✅ |
| **session 导航面板**（按 prompt/运行命令/状态 筛选跳转） | ❌ | 🟡（events/notification 跳转） | ✅ Session Navigation Palette |
| **agent hibernation**（杀闲置后台 agent 省内存，回到 tab 自动 resume） | ❌ | ✅ 可配 idleSeconds/maxLiveTerminals | — |

**conductor 缺什么（细）**：
- 🟠 **Agent hibernation**：后台闲置 agent 进程自动挂起释放内存，回到该 tab 时按 resume 命令自动恢复，可配空闲秒数与最多保活终端数。开很多 agent 时这是省内存的关键能力。
- 🟢 session 导航面板（按运行中命令/状态/最近命令过滤跳转）。
- ✅ **会话续聊这块 conductor 已做得相当完整**，是强项之一。

---

### D. 通知 / 待处理状态 / Feed 审批

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 完成/需关注桌面通知 | ✅ rich + osascript 兜底 | ✅ | ✅ |
| 点通知跳回对应 pane | ✅ | ✅ | ✅ jump to pane |
| tab/侧栏未读/完成标记 | ✅ 绿点 + thinking 动画 | ✅ **pane 蓝环** + tab 高亮 | ✅ Agent 管理面板 |
| 通知面板/中心 | ✅ ActivityCenter | ✅ NotificationsPage + 侧栏角标 | — |
| 跳到最近未读 | 🟡（活动中心） | ✅ ⌘⇧U / ⌥⌘U / ⌃⌘U 一整套 | — |
| OSC 终端序列检测 | 🟡 OSC 9;4 进度 | ✅ OSC 9 / 99 / 777 | — |
| 通知声音设置 | ❌ | ✅ 可配自定义声音 | — |
| 尊重"勿扰/专注"模式 | ❌ | ✅ | — |
| **可组合通知 hook 管道**（jq/sed 过滤、控制 banner/声音/命令/重排） | ❌ | ✅ cmux.json notifications.hooks[] | — |
| **Feed 内联审批**（权限请求 Once/Always/All/Deny、ExitPlan、AskUserQuestion，在 app 里直接批） | 🟡 仅"待处理"提示，要跳 pane 手动操作 | ✅ Feed（右侧栏/Dock/TUI + 120s 软等待 + 审计日志） | ✅ Agent permissions + 远程操控 |
| **事件流**（可重连、分类、JSONL 审计） | 🟡 自研 automation socket，无文档化事件流 | ✅ `cmux events`（window/workspace/pane/surface/notification/feed/agent + cursor 重放） | — |
| 通知转发到手机 | ❌ | ✅ APNs + iOS app | ✅ 手机操控 session |

**conductor 缺什么（细）**：
- 🔴 **Feed 式内联审批 UI**：agent 请求权限/ExitPlan/提问时，**在 conductor 里直接按钮批准/拒绝**（Once / Always / All tools / Deny），而不是跳进 pane 手敲。这是"并行盯多个 agent"的核心提效点，cmux 的招牌之一。
- 🟠 **pane 蓝环 + 完整未读跳转键位**（⌘⇧U 等）。
- 🟠 **OSC 9/99/777 序列检测**（不依赖 hook 也能感知 agent 状态）。
- 🟠 **可组合通知 hook 管道**（用户用 jq/sed 自定义哪些通知出 banner/响声/执行命令/重排工作区）。
- 🟠 **文档化事件流**（外部工具可订阅 conductor 的 window/pane/agent 生命周期事件，带重连和审计）。
- 🟢 通知声音 / 勿扰模式尊重。

---

### E. Agent provider 支持广度

| 维度 | Conductor | cmux | Warp |
|---|---|---|---|
| CLI 检测 | ✅ Codex/Claude/Gemini/Cursor/Copilot/Grok + 自定义（6+） | ✅ 15+ | ✅ 自动检测 10+（toolbelt） |
| Hook/会话续聊集成的 agent | 🟡 主要 Claude/Codex | ✅ **15 种**：Claude、Codex、Grok、OpenCode、Pi、OMP、Amp、Cursor、Gemini、Kiro、Rovo Dev、Copilot、CodeBuddy、Factory、Qoder | ✅ Claude Code/Codex/OpenCode/Amp/Auggie/Copilot/Cursor/Gemini/Droid/Pi |
| 用量统计覆盖的 provider | ✅ **48 个**（含 Claude/Codex/OpenAI/Gemini/Cursor/Copilot/Grok/Bedrock/Azure/DeepSeek/Ollama/Mistral/Perplexity…） | 🟡 仅云 VM 计费 | 🟡 仅自家 credit |
| 自动命名工作区（让 agent 总结对话起名） | ❌ | ✅ 适配 Claude/Codex/Grok/OpenCode/Pi/OMP | — |
| teams 模式（子 agent 作为原生 pane） | ❌ | ✅ `claude-teams` / `codex-teams` | ✅ 多 agent 面板 |

**conductor 缺什么（细）**：
- 🟠 **续聊/Hook 集成的 agent 种类**：conductor 续聊主要覆盖 Claude/Codex；cmux 把 resume 命令、hook 桥、会话探测做到 15 种 agent（每种的 resume 命令、session-id 来源都不同）。可借鉴 cmux 的 `vault.agents[]` 通用注册机制（声明：探测进程、session-id 来源、resume/fork 命令）。
- 🟠 **工作区/标签 AI 自动命名**（按对话内容自动给 tab 起名，手动名优先）。
- 🟢 **teams 模式**（claude-teams/codex-teams 把子 agent 拉成原生分屏 pane）。
- ✅ **用量 provider 覆盖（48 个）是 conductor 的绝对强项**，两个竞品都没有可比的东西。

---

### F. MCP / Hooks / Skills 管理

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| Skills 管理 UI | ✅ 跨工具（Claude/Codex/Gemini/Cursor/Copilot）统一管理 | 🟡 自带 18+ skill + `skills.sh` 安装到 codex | — |
| Skills 来源（git/本地/导入）+ 同步（copy/symlink） | ✅ | 🟡（脚本安装） | — |
| Hooks 管理 UI | ✅ 编辑优先，Claude settings.json + Codex hooks.json，事件 Stop/SessionStart/UserPromptSubmit/SubagentStop/Notification，安装器 + parking | ✅ claude-hook/codex-hook/feed-hook + session 映射 | — |
| MCP 管理 | ✅ AgentToolsMCPWorkbench（与 skills 一起管） | 🟡 agent 启动时传 `--mcp-config`/`--strict-mcp-config`，社区 MCP 桥 | ✅ **应用内 MCP**（GitHub/Linear/Jira；HTTP+SSE；OAuth/Bearer；云 agent 也能用） |
| 命令片段库（占位符填充） | ✅ SnippetStore + fill panel | 🟡（custom commands 部分覆盖） | ✅ Workflows |
| **项目级自定义命令/动作**（命令面板里跑项目专属动作） | 🟡 仅全局 snippet | ✅ cmux.json `actions{}`（.cmux/cmux.json 逐目录合并，按钮/图标/快捷键/信任门） | ✅ Workflows + Drive |

**conductor 缺什么（细）**：
- 🟠 **项目级目录动作**：在 `项目/.cmux` 里声明专属命令（构建/部署/起服务），逐目录向上合并，出现在命令面板 / surface 工具栏按钮 / 右键，带项目信任门。比全局 snippet 更贴工作流。
- 🟢 应用内 MCP 一键 OAuth 连接（GitHub/Linear/Jira 这类托管 MCP）——Warp 体验更顺。
- ✅ **跨工具统一管理 Skills/Hooks/MCP 的 workbench UI 是 conductor 强项**，cmux 是散装脚本，Warp 没有跨工具概念。

---

### G. 内置浏览器 + 可脚本化浏览器 API 🔴🔴

> **这是 conductor 相对 cmux 最大的整块空白：完全没有。**

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 内置浏览器 pane（WKWebView，分屏并排） | ❌ | ✅ BrowserPanel（536KB 实现） | ❌（Warp 也没有） |
| 地址栏/omnibar + 搜索建议 + 自定义搜索引擎 | ❌ | ✅ | — |
| 前进/后退/刷新/缩放/DevTools/JS 控制台 | ❌ | ✅ ⌘[/]/R、⌥⌘I、⌥⌘C | — |
| 页内查找 | ❌ | ✅ ⌘F | — |
| **浏览器配置导入**（Chrome/Firefox/Arc/Safari 等 20+ 浏览器的 cookie/历史/会话，让浏览器 pane 开箱即登录态） | 🟡 **有底层能力但用途不同**：SweetCookieKit 已能读 Chrome/Safari/Gecko cookie，但目前只用于"取用量 provider 的鉴权"，没有浏览器去承接 | ✅ `cmux browser cookies import` | — |
| Passkey/WebAuthn/2FA/OAuth 弹窗 | ❌ | ✅（window.open 共享 OAuth 上下文） | — |
| 截图 / 下载处理 / 媒体播放 | ❌ | ✅ | — |
| React Grab（页面选元素） | ❌ | ✅ ⌘⇧G | — |
| 系统代理镜像 / HTTP host 白名单 | ❌ | ✅ | — |
| **可脚本化浏览器自动化 API**（agent-browser 移植：navigate/click/fill/type/eval/wait/screenshot/snapshot 无障碍树+元素 ref、locator by role/text/label、frame/dialog/download、cookies/storage、route 拦截、console/errors、state save/load） | ❌ | ✅ 完整一套（CLI + 文档 agent-browser-port-spec.md） | 🟡（agent 有 web search，但非可脚本浏览器） |

**conductor 缺什么（细）**：
- 🔴 **整个内置浏览器 + 可脚本化浏览器 API**。对"让 agent 自己开浏览器验证 / 截图 / 跑 e2e / 登录态操作"的工作流，这是 cmux 的杀手锏，conductor 0 覆盖。
- ✨ **可复用的现成基础**：conductor 已有 `SweetCookieKit`（Chrome/Safari/Gecko cookie 导入 + keychain 门控），只是现在喂给用量统计。**若要做浏览器 pane，cookie 导入这块的轮子已经造好了**，能直接接上"浏览器开箱登录态"。
- 实现参考：cmux 的浏览器自动化是移植自 `vercel-labs/agent-browser`，规范在其 `docs/agent-browser-port-spec.md`，可直接对照。

---

### H. Git / worktree / PR / diff review

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 状态栏显示 git 分支 | ✅ | ✅（侧栏每行显示） | ✅ prompt chip |
| **git worktree per-agent 隔离** | ❌ | ✅ CmuxGit（解析 .git、worktree、submodule、include 链） | — |
| **PR 徽标**（侧栏显示分支关联 PR 号+合并状态，自动刷新） | ❌ | ✅ PullRequestProbeService | — |
| git index 快照（staged/unstaged） | ❌ | ✅ GitIndexSnapshot | ✅ Code review |
| **diff viewer**（查看/审阅代码 diff，行内评论，附给 agent） | ❌ | ✅ CodeView diff + per-repo 评论 + attach 给 agent | ✅ Code review 面板 + 行内评论 + revert hunk |
| **代码编辑器**（语法高亮/find&replace/文件树/Vim/LSP） | ❌ | 🟡（文件预览有文本编辑器） | ✅ Warp Code（含 LSP：Rust/Go/Py/TS/C++） |

**conductor 缺什么（细）**：
- 🟠 **git worktree per-agent 隔离**：每个 agent 在独立 worktree/分支干活，互不踩。多 agent 并行的标配。
- 🟠 **侧栏 PR 徽标**：分支→PR 号+合并状态，定期刷新。
- 🟠 **diff viewer + 行内评论 + 附给 agent**：审阅 agent 改动、圈点反馈再回灌给 agent。cmux/Warp 都有，conductor 完全没有。
- ⚪ 内置代码编辑器 + LSP（Warp Code）属重投入，与"真终端工作台"定位偏远，可暂缓。

---

### I. 远程 / SSH / 云沙箱 🔴

> **conductor 完全没有远程能力。**

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| `cmux ssh user@host` 远程工作区 | ❌ | ✅ + `-A` agent 转发 + `--no-focus` | ✅ SSH 扩展（远端装伴随 server，无开端口） |
| 可断线重连的 SSH PTY 守护 | ❌ | ✅ ssh-session-list/attach/cleanup | — |
| 远端 daemon 自举（下载校验 cmuxd-remote） | ❌ | ✅ SHA-256 校验 + 持久 slot | — |
| 远程 tmux 镜像 | ❌ | ✅ RemoteTmuxSessionMirror | — |
| 浏览器 pane 走远端网络 / scp 拖图上传 | ❌ | ✅ | — |
| **云 VM/沙箱**（按 agent 起隔离环境） | ❌ | ✅ E2B + Freestyle，`cmux vm new/ls/rm/exec/shell/attach/ssh` | ✅ Cloud agents（自托管/Warp 云，定义 repo/Docker/setup） |
| VM 计费/额度/lease | ❌ | ✅ Postgres 控制面 + 额度 + lease token | ✅ credit |

**conductor 缺什么（细）**：
- 🔴/🟠 **SSH 远程工作区**（最实用的一档）：本地 conductor 直接开远程机器的工作区 pane，断线重连不丢，浏览器/文件侧栏跟随远端根。这是远程能力里 ROI 最高的，建议优先于云 VM。
- 🟢 **云沙箱/VM**（E2B/Freestyle）：每个 agent 起隔离云环境。重投入（要后端控制面 + 计费），按产品方向决定是否做。
- ⚪ 远端 daemon 自举 / 远程 tmux 镜像属配套设施。

---

### J. CLI / socket 可脚本化 API

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| socket 控制 app | ✅ AutomationSocketServer | ✅ Unix socket v1+v2（handle-based） | 🟡 URI scheme |
| 命令覆盖面 | 🟡（新 tab/分屏等基础） | ✅ **70+ 子命令**：workspace/pane/surface/window/notification/feed/status/progress/log/events/browser/vm/ssh/tmux-compat… | 🟡 |
| 短引用（surface:N/pane:N/workspace:N） + `--id-format` | ❌ | ✅ | — |
| tmux 兼容调度（resize/swap/break/join/popup/bind-key…） | ❌ | ✅ | — |
| 发文本/按键到指定 pane | 🟡 | ✅ send/send-key/send-panel/read-screen/capture-pane | — |
| 侧栏元数据 CLI（set-status/progress/log） | 🟡 WorkspaceMetadataCenter 有数据，CLI 暴露弱 | ✅ set-status/clear-status/set-progress/log | — |

**conductor 缺什么（细）**：
- 🟠 **CLI 命令覆盖面**：conductor 的 automation socket 只覆盖基础动作。cmux 的 70+ 子命令让 agent/脚本能完全驱动 UI（建工作区、分屏、发按键、读屏、设状态/进度、订阅事件）。这是"可脚本化"卖点的地基。
- 🟢 短引用寻址 + tmux 兼容层（让 tmux 用户/脚本平滑迁移）。

---

### K. 文件浏览 / 预览 / Markdown / 查看器

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 文件夹树侧栏 | ✅ SidebarFolderTree（懒加载） | ✅ Finder 式文件浏览（SSH 感知） | ✅ 文件树 |
| **文件预览面板**（图片/PDF/QuickLook/文本编辑/媒体/自动换行） | ❌ | ✅ FilePreviewPanel（160KB，全套） | 🟡（Code 编辑器） |
| **Markdown 查看器**（渲染 + 实时重载 + Mermaid + 字号/缩放） | ❌（仅 skill 描述渲染） | ✅ `cmux markdown open` | — |
| 插入路径/相对路径、Finder 显示 | 🟡（右键复制 cwd / open in Finder） | ✅ Insert Path/Relative Path | — |

**conductor 缺什么（细）**：
- 🟠 **Markdown 查看器**：agent 经常产出 `.md`（计划/报告/AGENTS.md），需要能渲染+实时重载预览。
- 🟢 **富文件预览面板**（图片/PDF/QuickLook/媒体）。

---

### L. 命令补全 / 历史 / 自动建议（Warp 强项，⚪ 设计取向）

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| Tab 补全（400+ CLI spec） | ⚪ 依赖 shell | ⚪ 依赖 shell | ✅ 自研 |
| 历史 inline autosuggestion | ⚪ 依赖 shell | ⚪ 依赖 shell | ✅ |
| 命令纠错（thefuck 式） | ❌ | ❌ | ✅ |
| 命令检查器/X-Ray（实时拆解 flag/子命令） | ❌ | ❌ | ✅ ⌘⇧I |
| 语法高亮 / 错误下划线 | ⚪ 依赖 shell | ⚪ 依赖 shell | ✅ |
| 富命令历史（退出码/cwd/分支/耗时） | ❌ | 🟡（events 有元数据） | ✅ ⌃R |

**说明**：这一整块是 Warp 自研输入框/补全引擎的产物。conductor 和 cmux 都用真 shell + Ghostty，**这些本就交给用户的 shell（zsh/fish + starship）**，与"真终端"定位一致。**⚪ 不建议自研**——除非要做 Warp 那种 ADE。最多可考虑 🟢 富命令历史面板。

---

### M. 主题 / 外观 / 字体

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 内置主题数 | 🟡 6（dark/light/tokyo-night/catppuccin/nord/rose-pine）+ 自定义 hex | ✅ 复用全部 Ghostty 主题 + 选择器 | ✅ 535 主题（含渐变/背景图） |
| 跟随系统亮/暗 | ✅ | ✅ + 条件主题 `dark:X,light:Y` | ✅ system sync |
| 主题选择器 UI | 🟡（设置里选） | ✅ `cmux themes` 实时选择器 | ✅ 选择器 + 从图片生成主题 |
| 字体族/字号/行高/连字 | 🟡 字体族+字号 | ✅（复用 ghostty） | ✅ 全套 + ligatures |
| 背景图/模糊 | ❌ | ✅ | ✅ background_image + opacity |
| 配置热重载 | ✅ ConfigWatcher | ✅ | ✅ settings.toml 双向 |

**conductor 缺什么（细）**：
- 🟢 **复用 Ghostty 主题生态**：cmux 直接吃 `~/.config/ghostty` 的主题/字体，等于白嫖整个 Ghostty 主题库；conductor 只有 6 个内置 + 手填 hex。
- 🟢 主题实时选择器、背景图/模糊、行高/连字。

---

### N. 设置 / 配置系统

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 配置文件 | ✅ `~/.config/conductor/config.yaml`（YAML/Yams） | ✅ `~/.config/cmux/cmux.json`（JSONC） | ✅ `settings.toml` |
| 配置热重载 | ✅ | ✅ ⌘⇧, reload | ✅ 双向 |
| 键位自定义 | ✅ config.yaml keybindings + KeyChord 解析 | ✅ shortcuts.bindings（含 chord/`when` 上下文/解绑）+ 6+ 预设模板 | ✅ keysets（default/emacs）+ 冲突高亮 |
| 设置 UI 分区 | ✅ appearance/terminal/ghostty/behavior/keybindings | ✅ 12+ 区 | ✅ 多区 |
| **跨设备设置同步** | ❌ | 🙰 | ✅ Settings Sync（beta） |
| 从 iTerm2/Windows Terminal 导入 | ❌ | ✅ 浏览器/ghostty 配置导入 | ✅ |
| 键位预设模板 | ❌ | ✅ Tmux/iTerm/Vim/Agent-Triage 等 6+ | ✅ |
| `when` 上下文条件键位 | ❌ | ✅ | — |

**conductor 缺什么（细）**：
- 🟢 键位预设模板（Tmux/Vim/iTerm 风格一键套用）。
- 🟢 `when` 上下文条件键位（终端 vs 浏览器 vs diff 不同绑定）。
- 🟢 跨设备设置同步。

---

### O. 用量 / 成本统计 ✅（conductor 强项，反向领先）

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 多 provider 用量 | ✅ **48 个 provider** | ❌（只云 VM 计费） | 🟡 只统计自家 credit |
| 速率窗口（session/weekly/自定义） | ✅ UsageModels | — | 🟡 |
| 成本快照（used/limit/币种/重置时间） | ✅ | — | 🟡 |
| 历史趋势图 | ✅ UsageTrendChart | — | 🟡 |
| 凭证输入（API key/cookie/projectID） | ✅ + SweetCookieKit 读浏览器 cookie 鉴权 | — | — |
| 后台周期刷新 | ✅ UsageMonitor | — | — |
| 按时间/项目/模型/token 拆解 | ✅ 扫 `~/.claude/projects` & `~/.codex/sessions` | — | — |

**结论**：**这块 conductor 明显领先，是差异化卖点。** 两个竞品都只统计自己那点东西。建议继续投入（把它做成 conductor 的标志能力），别因为补别的短板而冷落它。

---

### P. iOS / 移动端 / 跨设备 🔴

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| iOS 伴随 app | ❌ | ✅（TestFlight beta，从手机连 Mac 终端） | 🟡 web/手机浏览器操控 session |
| 配对（QR/设备注册表） | ❌ | ✅ | — |
| 手机操控 agent / 看 transcript | ❌ | ✅ iMessage 式编辑器 + 草稿 | ✅ 远程操控 session |
| 通知转发到手机（APNs，离开 Mac 才推） | ❌ | ✅ | ✅ |
| 跨设备会话同步 | ❌ | 🟡（presence worker） | ✅ 云同步对话 |
| 设备在线状态（presence） | ❌ | ✅ Cloudflare DO presence | ✅ |

**conductor 缺什么（细）**：
- 🟢/🟠 **整个移动端 + 跨设备**。重投入（要 app + 后端 presence + APNs）。按产品野心决定，**短期优先级低于浏览器/远程/Feed**。

---

### Q. 团队 / 协作 / 分享（Warp 强项，⚪/🟢）

| 小功能 | Conductor | cmux | Warp |
|---|---|---|---|
| 分享 block/session 链接 | ❌ | ❌ | ✅ Session Sharing（实时、可授查看/编辑） |
| Agent session 共享（看 prompt/思考/工具调用） | ❌ | ❌ | ✅ |
| 团队 Drive（共享 workflow/notebook/prompt/rules/env） | ❌ | ❌ | ✅ Warp Drive |
| SSO/SCIM/Admin 面板/密钥脱敏 | ❌ | 🟡（Stack Auth + 团队设备注册） | ✅ 企业级 |
| 反馈/共享计划收集 | ✅ CoCreate | 🟡 feedback API | — |

**说明**：协作/团队是 Warp 商业化重头。conductor/cmux 都几乎没有。⚪ 与当前定位偏远，🟢 可先做轻量的"分享某次 agent run 的 transcript 链接"。

---

### R. Warp AI 原生能力（⚪ 设计取向不同，谨慎借鉴）

Warp 自研了一整套 agent（Oz）：planning mode、task list、web search、多 repo、active AI 建议、NL→command（Generate）、suggested diffs、voice 输入、rules（AGENTS.md/WARP.md）、agent profiles + 细粒度权限（allowlist/denylist/YOLO）、多 agent 面板、cloud agents、ambient agents（Slack @ / GitHub CI / cron 触发）。

**对 conductor 的意义**：conductor 的定位是**编排外部 agent（claude/codex），不自研 agent**。所以：
- ⚪ **不建议自研 agent/planning/NL→command/voice** —— 那是另一个产品。
- 🟠 但其中**两点值得借鉴到"编排层"**：
  1. **细粒度权限/审批模型**（对应 §D 的 Feed）——把 agent 的权限请求在 conductor 层做成 allow/deny/always 的可视审批。
  2. **rules / 上下文文件感知**（AGENTS.md/WARP.md）——conductor 已在管 skills/hooks，可顺带感知并展示项目的 AGENTS.md/CLAUDE.md。

---

## 3. Conductor 的相对优势（别只盯短板）

1. **🏆 多 provider 用量/成本面板（48 providers + 趋势图 + 速率窗口）**——两个竞品都没有可比物，是最硬的差异化。
2. **🏆 跨工具统一的 Skills/Hooks/MCP 管理 workbench**——cmux 是散装脚本，Warp 无跨工具概念。
3. **✅ 会话续聊完整度**（claude/codex 自动 resume + 通用 surface resume 绑定 + 信任模型）。
4. **✅ 任务队列**（给 pane 排队下一条指令，上轮结束自动跑）——cmux/Warp 无直接对应。
5. **✅ Mission Control（⌘⇧M）实时 pane 预览**。
6. **✅ SweetCookieKit**（已能导入 Chrome/Safari/Gecko cookie）——做浏览器 pane 时是现成轮子。

---

## 4. 差距优先级与建议路线图

> 排序依据：① 对"并行盯多个 agent"工作流的提效；② 相对 cmux（最直接竞品）的可见差距；③ 实现 ROI。

### 🔴 P0（核心竞争力缺口，建议尽快）
1. **Feed 式内联审批 UI**（§D）——agent 权限/ExitPlan/提问在 app 内直接批，不用跳 pane。提效最直接。
2. **侧栏/标签富信息**（§A）——每个工作区/tab 显示 git 分支 + PR 状态 + 监听端口 + 最新通知。"一眼看全"的核心体验。
3. **内置浏览器 pane + 可脚本化浏览器 API**（§G）——cmux 杀手锏，conductor 0 覆盖；SweetCookieKit 可复用降低成本。

### 🟠 P1（明显短板）
4. **Agent hibernation**（§C）——闲置 agent 自动挂起省内存，回 tab 自动 resume。
5. **工作区分组 + 竖向 tab + 多窗口**（§A）——多 agent 的组织能力。
6. **diff viewer + 行内评论 + 附给 agent**（§H）+ **git worktree per-agent 隔离** + **PR 徽标**。
7. **SSH 远程工作区**（§I，先做 SSH，云 VM 缓）。
8. **CLI 命令覆盖面扩到可完全驱动 UI**（§J）+ **文档化事件流**（§D）。
9. **更广的 agent 续聊/hook 集成**（借 cmux `vault.agents[]` 通用注册）+ **工作区 AI 自动命名**（§E）。
10. **Markdown 查看器**（§M）。

### 🟢 P2（锦上添花）
- 图片粘贴/文件拖入终端、OSC8 点击、vi copy mode（§B）
- 富文件预览面板（§M）、复用 ghostty 主题生态 + 主题选择器（§N）
- 键位预设模板 / `when` 条件键位 / 设置同步（§N）
- 通知声音、勿扰尊重、OSC 9/99/777、pane 蓝环（§D）
- 项目级目录动作 `.cmux/actions`（§F）、应用内 MCP OAuth（§F）

### ⚪ 设计取向不同（不建议无脑抄）
- Warp block 范式、自研补全/纠错/autosuggest（交给 shell）
- 自研 agent / planning / NL→command / voice（conductor 是编排器，不是 agent）
- 内置代码编辑器 + LSP（Warp Code，重投入且偏离定位）
- 完整团队/SSO/Drive（商业化路线，按野心决定）
- iOS/跨设备（重投入，排在浏览器/远程/Feed 之后）

---

## 附:三者一句话定位
- **Conductor**：macOS 原生多 agent 终端工作台，强在用量统计 + 跨工具工具链管理，是"看全局 + 接管终端"。
- **cmux**：同源同框（Ghostty/Swift）但盘子更大——多了内置浏览器、SSH/云 VM、iOS、Feed 审批、teams、70+ CLI，是 conductor **最该逐项对标的对手**。
- **Warp**：Rust 自研 GPU 终端 + 自研 Agent + Drive + Code 的 ADE，另一条路线，选择性借鉴其"权限审批模型"和"rules 上下文"。

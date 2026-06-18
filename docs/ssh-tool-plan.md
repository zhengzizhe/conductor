# SSH 工具：方案与交互设计说明

> 本文件是「SSH 工具」功能开工前的设计稿，对应 `GOAL.md` 固定流程第 3 步。
> 落代码前以本文为评审基准。**范围已收敛：不含 agent-over-SSH（用户明确暂不需要）**——见 §1 非目标。

## 1. 定位

Conductor 今天的连接源只有「本地」：一个 pane = 本机 `cwd` 起的 shell/PTY。**SSH 工具 = 把「远程主机」做成 Conductor 的一等连接源**——主机簿管很多台机器，一键把任一台开成 pane，远程机和本地 pane 在 tab/侧栏/分屏里平权。

调研结论（见 `docs/` 同目录调研记录与会话）：市面分两类——

- **连接管理器**（Termius / SecureCRT / Royal TSX / Asbru）：核心是「主机簿 + 连得舒服 + 密钥/隧道/SFTP/同步」。
- **嵌进开发工作流**（VS Code Remote / Warp Agent Mode）：把远程机当本地干活，含 agent over SSH。

**Conductor 取前者的骨架、用自己的终端模型长深度**，不抄后者的 agent 线。理由：Conductor 已有成熟的 pane / tab / 分屏 / 会话状态机和 libghostty 真 PTY——SSH 只要把「连接」喂进这套既有模型，深度（多机管理、状态可视、双接口自动化）就从 SSH 自身长出来，不靠堆功能。

**不做什么（非目标，守口味 / 深度优先铁律）：**

1. **不碰 agent over SSH**（本轮用户明确暂不需要）。不做「远程跑 claude/codex + 用量/审批回流」。架构上给它留了门（§5 transport 不阻断），但本方案零相关代码、零相关 UI。
2. **不自研 SSH 协议栈**。连接一律走系统 `ssh`（PTY 内）——ProxyJump 跳板链、agent-forwarding、`IdentityFile`、`ServerAliveInterval`、Mosh、压缩等**全部白嫖系统 ssh / `~/.ssh/config`**，我们一行 crypto 都不写。自研 libssh2/SwiftNIO-SSH 是给自己挖坑，且和「复用既有 PTY pane」相悖。
3. **不做又一个 Termius 云**。不做跨设备加密云同步 / 团队保险库（那是 Termius 的护城河，与 Conductor 定位正交）。主机簿是本地的，可选写回 `~/.ssh/config`（标准、可被其它工具复用）。
4. **SFTP / 文件传输**不进 MVP（大头，§10 列为深度二期）。

## 2. 结论先行：关键架构发现（已核实，注明文件行）

| 点 | 结论 | 证据 |
|---|---|---|
| 终端是**引擎无关协议** | SSH 无需新 surface 类型 | `ConductorCore/TerminalSurface.swift:5-20`：`start(cwd)/focus()/close()` + `onTitleChange/onCwdChange/onExit`。SSH 连接＝一个 PTY pane，初始命令是 `ssh …`，复用 `GhosttySurface` |
| Surface 由**工厂 + 生命周期效果**驱动 | 连接/断开/聚焦套现成机制 | `SessionRegistry.swift:19-37`：`apply(SessionEffect)` → `createSurface(pane,cwd)/closeSurface/focusSurface`。surface 退出回调 `onExit` 即「连接断开」信号 |
| **启动命令已被建模 + 脱敏** | 主机簿构 `ssh` argv 直接喂进去；密码/token 自动不落盘 | `AgentLaunchCommandSnapshot.swift:3-19`（`agent/argv/cwd`）+ `AgentLaunchCommandSanitizer`（`:147-157` 丢含 `password/secret/token/auth` 的参数）。SSH 复用这条「launch command」路径，与 agent 一键启动同源 |
| 启动器目录是**静态描述符表** | 加「SSH」入口＝加一条 + 一个 logo | `CLIToolsView.swift:82-151`：`AgentDescriptor`（id/name/logo/command/检测闭包）+ `AgentCatalog.all`。`LaunchableAgent`（`:73-80`）是一键启动模型 |
| 配置是**容错 Codable + 文件监听** | 主机簿落 `config.yaml` 新段，套现成模式 | `AppConfig.swift:8-58`（每结构 `init(from:)` 缺字段给默认、未知字段忽略、`validated()` 夹紧）+ `Config/ConfigStore.swift`/`ConfigWatcher.swift`（Yams + 热重载） |
| **socket 自动化**已成体系 | 双接口（AI/脚本驱动 SSH）顺势加方法 | `Automation/AppCoordinator+Automation.swift`：现有 `AutomationProtocol`（NDJSON + `{id,ok,result\|error}`）+ `AutomationError` 码 |
| **无任何 SSH/网络代码** | 干净起步，无历史包袱 | 全仓搜 `ssh`/`Network` 仅命中 cookie 导入；进程起子进程已在多处用 `Foundation.Process` |

**结论：零阻断。** SSH 工具的「连接」部分是把既有 PTY pane + launch command + 主机簿配置三块拼起来，无新子系统、无新依赖。

## 3. 架构

```
~/.ssh/config            ← 连接参数的事实来源（Host 块：HostName/User/Port/ProxyJump/IdentityFile…）
   │  解析（只读优先；手动新增可选写回）
   ▼
HostBook（ConductorCore，纯逻辑）
   │  Host 别名 + 连接参数（来自 ssh config）
   │  + Conductor 叠加层：分组/标签/颜色/上次连接/登录后 snippet（GUI-only 元数据）
   ▼
SSHCommandBuilder（ConductorCore，纯逻辑）   →  ssh argv  →  AgentLaunchCommandSnapshot
   │                                                              │（脱敏后可安全持久化/续连）
   ▼                                                              ▼
连接 = SessionEffect.createSurface(pane, cwd:nil) + 以 argv 起 ssh 的 PTY pane（GhosttySurface）
   │
   ├─ onTitleChange → tab/侧栏标题（远程 hostname）
   ├─ onExit        → 连接状态：断开（可触发「重连」）
   └─ 状态机：连接中 / 已连接 / 断开 / 失败    ← 叠在现有 pane 状态上（对标 paneAgents 叠 agent 身份）

UI（ConductorApp）
   ├─ 主机簿面板 / 侧栏「Hosts」组（分组/搜索/一键连）
   ├─ 命令面板（⌘K）：搜「连接到 <host>」
   ├─ 右键 pane / Tools 面板：在此开 SSH
   ├─ 主机编辑器（HostName/User/Port/跳板/密钥/转发，GUI 编辑 ssh config 块或叠加层）
   └─ 隧道管理（本地/远程/动态转发，列表 + 开关）

Automation（双接口）
   └─ ssh-list / ssh-connect / ssh-disconnect / ssh-state / ssh-tunnel-*  ← 复用 AutomationProtocol
```

**分层（守铁律 3a：纯逻辑抽到 `ConductorCore`）：**

- `ConductorCore/SSH/`：`SSHHost` 模型（Codable）、`~/.ssh/config` 解析器（Host 块、`Include`、`Match` 的安全子集）、`SSHCommandBuilder`（Host → argv）、`HostBook`（合并 ssh config + 叠加层、分组/搜索/排序）。**全部可单测，不依赖 Process / UI / 网络。**
- `ConductorApp/SSH/` + `UI/`：主机簿面板、主机编辑器、隧道管理、把连接接进 `SessionRegistry` / `AppCoordinator`、socket 方法。

## 4. 主机簿与数据模型（核心）

**事实来源 = `~/.ssh/config`（推荐，见 §11 未决 D1）。** 理由：power user 的主机/跳板/密钥已经在那；系统 `ssh` 连接时本就读它；写自有格式 = 和用户已有配置打架。Conductor 解析它得到主机列表，连接就是 `ssh <别名>`，**ProxyJump / IdentityFile / 转发等一律交给 ssh 解析，我们不重新实现**。

**Conductor 叠加层**只存 ssh config 表达不了的「展示 / 工作流」元数据，按 Host 别名为键，落 `config.yaml` 的 `ssh:` 段或独立 `ssh-hosts.json`：

```yaml
ssh:
  hosts:
    prod-web:                 # 键 = ~/.ssh/config 里的 Host 别名
      group: "生产"
      tags: ["web", "us-east"]
      color: "#C0392B"
      onConnect: "cd /srv && git status"   # 登录后自动跑的 snippet（可选）
    # GUI 里手填、不在 ssh config 的主机：完整连接参数也存这（可选写回 ~/.ssh/config）
  options:
    importSSHConfig: true
    confirmBeforeConnect: false
```

`SSHHost`（纯模型，Codable，套 `AppConfig` 的容错 `init(from:)` + `validated()`）：

```
SSHHost {
  alias        // 唯一键 / 显示名
  hostName     // 来自 ssh config 或 GUI
  user, port
  proxyJump    // 跳板链（"bastion" 或 "a,b,c"）——展示用，连接交给 ssh
  identityFile // 密钥路径（不存私钥内容）
  forwards     // [PortForward]：local/remote/dynamic + bind + target
  source       // .sshConfig（只读解析） / .conductor（GUI 管理）
  // 叠加层：group, tags, color, lastConnectedAt, onConnect
}
```

**安全铁律**：私钥、密码、passphrase **一律不进 Conductor 存储**。认证交给系统 ssh + `ssh-agent`（agent-forwarding 走 ssh config 的 `ForwardAgent`）。`AgentLaunchCommandSanitizer` 已经会把含 `password/secret/token/key/auth` 的参数从持久化的 launch snapshot 里剥掉（`:147-157`），续连/历史天然不泄密。

## 5. Transport：连接 = PTY pane 跑 `ssh`（关键决策）

**MVP：连接就是一个普通 PTY pane，初始命令 `ssh <argv>`。** 复用 `GhosttySurface`，零新 surface。`SSHCommandBuilder` 把 `SSHHost` 编成 argv（别名优先：`ssh prod-web`，让 ssh config 自己解析参数）。这条路白嫖系统 ssh 的全部能力，且和「一键起 agent」同一条 launch-command 通道。

**连接状态可视（深度，仍复用既有机制，不新建子系统）**：在 pane 上叠一层「SSH 连接身份 + 状态」，完全对标今天 `paneAgents` 在 pane 上叠 agent 身份的做法：

- `onTitleChange`（OSC 标题）→ tab/侧栏显示远程 hostname。
- `onExit(code)` → 连接断开；非零码且非用户主动 = 异常断开，给「重连」入口（重连 = 用同一 snapshot 重跑 ssh）。
- 连接中 / 已连 / 断开 / 失败 四态 → tab 指示点 + 侧栏 badge（复用现有 pane 状态指示组件，守口味铁律不自造视觉）。

**断线韧性**：MVP 靠 ssh config 的 `ServerAliveInterval`（主机编辑器可一键写入）。Mosh 作为可选：若检测到本地 + 远程有 `mosh`，主机可勾「用 Mosh 连」→ builder 改发 `mosh` argv（漫游 + 断线续连，移动网络体验远好于裸 ssh）。属深度二期。

**为什么不立刻做专用 `SSHSurface`**：它能多给「进程级重连 / 结构化连接事件」，但 MVP 用 launch-command + `onExit` 已覆盖连接/断开/重连。专用 surface 留作深度选项（§10），不在关键路径上挖。

## 6. 隧道 / 端口转发（深度，仍走系统 ssh）

转发是 SSH 高频刚需，且系统 ssh 全包，我们只做 GUI：

- 主机编辑器里配 `forwards`：本地（`-L`）/ 远程（`-R`）/ 动态 SOCKS（`-D`），写进连接 argv 或 ssh config。
- **独立隧道**（不开交互 shell、只挂转发）：`ssh -N -L …` 起一个**后台 PTY-less Process**（不占 pane），隧道管理面板列出「目标 / 端口 / 状态」+ 开关 + 日志。复用 `Foundation.Process`（仓库已多处用）。
- 状态可视：建立中 / 活跃 / 失败 / 已停。
- 双接口：`ssh-tunnel-open/close/list`。

## 7. 交互设计说明（GOAL 第 3 步四块）

### ① 交互完整性（全状态）

- **正常态**：主机簿（分组折叠 / 搜索 / 最近连接置顶）；一键连 → pane 出现连接中转圈 → 已连接进交互。
- **空态**：无任何主机 → 引导卡（「导入 `~/.ssh/config`」+「手动添加主机」+ 示例）。
- **加载态**：解析 ssh config / 建立连接有明确进度与转圈。
- **错误态**：连接失败（DNS / 拒绝 / 认证失败 / 跳板不可达）→ 把 ssh stderr 收敛成**可读错误 + 下一步**（「检查密钥」/「主机不可达」/「重连」），不是吐裸日志。
- **未配置态**：本地无 `ssh` 二进制（极少）→ 提示；密钥需 passphrase → 交给系统 ssh-agent / 终端内提示，不在 Conductor 弹自造密码框（不碰私钥铁律）。
- **极端量**：上百主机 → 搜索 + 分组 + 虚拟化列表；超长会话/输出由 Ghostty PTY 自理。
- **可逆**：连接 / 断开 / 重连 / 开关隧道都即时反馈、可撤；破坏性操作（删主机）二次确认。

### ② 人好用（GUI 一等公民）

- **多入口**：命令面板（⌘K 搜「连接到 X」）；侧栏「Hosts」组一键连；右键 pane / Tools 面板「在此开 SSH」；主机编辑器表单。
- **键盘优先**：连接 / 断开 / 切主机 / 新建全可键盘完成；新快捷键经 `KeyChord` 注册 + 冲突检测。
- **可发现性**：命令面板可搜、空态引导、状态自解释。
- **一致性**：复用现有 `Theme`（accent/语义色/间距/圆角）、侧栏/tab/分屏组件、SF Symbols；面板宽度走 `PanelWidthStore` + `PanelResizeHandle`。**不自造视觉**（守口味铁律：不发闷渐变/玻璃，用成熟配色）。
- **本地化 + 无障碍**：文案走 `L(...)` 中英；动态字号不破版；控件可访问性标签。
- **性能**：ssh config 解析 / 连接探测在后台队列；主线程不卡。

### ③ AI / 脚本好调用（机器接口一等公民，守双接口铁律）

`AppCoordinator+Automation` 新增（复用 `AutomationProtocol` NDJSON + `AutomationError`）：

- `ssh-list`（query）→ 主机簿（别名/分组/标签/状态）。
- `ssh-connect`（params: `host` 别名或 `user@hostname`，可选 `split`/`tab`）→ 返回 `pane:N` 短引用。
- `ssh-disconnect` / `ssh-reconnect`（addressing by `pane:N`）。
- `ssh-state`（query：某 pane 的连接态）。
- `ssh-tunnel-open` / `ssh-tunnel-close` / `ssh-tunnel-list`。

**稳定寻址** `pane:N`（复用现有 pane 寻址）；**结构化 I/O**；**明确错误**用现有码；**行为对齐**——GUI 连接与 socket 连接打同一条 `SessionRegistry` 路径，零分叉。

### ④ 商业化打磨

- **截图门面级**：主机簿（分组 + 状态点 + 最近连接）默认即好看、信息密度合适，可直接进官网截图。
- **首次体验**：一键「导入 `~/.ssh/config`」秒出主机列表（多数用户零配置即用）。
- **文案专业**：错误给「下一步怎么办」，无裸 stderr / TODO / 占位串。

## 8. 数据 / 状态模型 + 测试计划（守 testing-bar：穷尽 + 真跑 + 连 UI 验）

`ConductorCore/SSH/` 纯逻辑 + 单测，覆盖**正常 + 边界 + 异常**：

- **ssh config 解析器**：`Host` 通配（`*`、`?`）、多别名、`Include`、`Match`、大小写不敏感关键字、注释/空行、`ProxyJump`/`IdentityFile`/`LocalForward` 等；畸形行不崩、未知关键字忽略（向前兼容）。
- **`SSHCommandBuilder`**：别名连接 vs 全参数连接、跳板链、转发（-L/-R/-D）、Mosh 分支、端口/用户缺省；**确保不把密码/passphrase 拼进 argv**。
- **`HostBook` 合并**：ssh config + 叠加层按别名 join、分组/标签/搜索/排序、叠加层指向已删主机的容错。
- **脱敏往返**：`AgentLaunchCommandSanitizer` 对 ssh argv 的行为（敏感参数被剥，别名/Host/Port 保留）。
- **socket 方法**：`ssh-connect/list/state/tunnel-*` 的参数校验、寻址、错误码。

`swift test` 全绿 + `swift build` 通过 + **dev app 真跑 + UI 截图**（独立 bundle id、独立 `CONDUCTOR_STATE_DIR`，绝不碰用户实例，只 kill 自己 PID）。验收含：真连一台 SSH（localhost `ssh localhost` 或一台测试机）→ 连接中/已连/断开/重连四态截图 + 一条隧道开关截图。

## 9. 安全

- **零私钥 / 零密码持久化**：认证全交系统 ssh + `ssh-agent`；Conductor 只存别名与展示元数据。
- **launch snapshot 脱敏**已就位（`:147-157`），续连/历史不泄密。
- **写回 `~/.ssh/config`**（若启用）：只写非敏感连接参数，备份原文件，绝不写密码；解析/写回要防注入（别名/值转义）。
- **known_hosts**：交给系统 ssh（首次连接的指纹确认在 PTY 内正常进行，不拦截、不自造信任）。

## 10. 分期 + 完成定义

- **Phase 1（MVP）**：`ConductorCore/SSH/`（模型 + ssh config 解析 + builder + HostBook，全单测）+ 主机簿面板/侧栏组 + 一键连接（PTY pane 跑 ssh）+ 连接四态可视 + 命令面板/右键入口 + 导入 `~/.ssh/config` + `ssh-connect/list/state/disconnect` socket。→ 能管多台机、一键连、状态清楚、可被脚本驱动。
- **Phase 2（深度）**：主机编辑器（GUI 编辑 ssh config 块）+ 隧道管理（-L/-R/-D + 独立隧道进程）+ 登录后 snippet + 重连/`ServerAliveInterval` 一键写入 + 写回 ssh config + `ssh-tunnel-*` socket。
- **Phase 3（可选深度）**：SFTP 文件浏览/传输；Mosh 支持；专用 `SSHSurface`（进程级重连/结构化连接事件）；集群广播（一条命令发多机，对标 Asbru/SecureCRT）。

**完成定义**（守铁律 2/3）：商业化产品级（能进截图/release notes）；`swift test` 全绿（含 `ConductorCore/SSH` 新测）；dev app 真跑 + 真连一台 SSH 的四态 + 隧道开关截图留证。

## 11. 风险与未决

1. **ssh config 解析的完整性**：`Match`/`Include`/通配优先级有坑——解析器只做「读出主机列表 + 展示」的安全子集，**连接永远交给系统 ssh**（我们的解析只影响显示，不影响连得上），把风险降到「最多显示不全」而非「连错机器」。
2. **连接状态的准确性**：靠 `onExit` 判断断开够用，但「卡住但没退出」（网络黑洞）测不准——靠 `ServerAliveInterval` 让 ssh 自己超时退出，比我们猜更可靠。
3. **PTY 内交互提示**（指纹确认 / passphrase / 2FA）：必须让它们在 pane 里正常显示给用户，Conductor 不拦不代答（不碰私钥/凭据铁律）。

**待决策（评审拍板）：**

- **D1｜主机簿事实来源**：推荐「`~/.ssh/config` 为准 + Conductor 叠加层」（最省心、与生态兼容）。备选「Conductor 自管为准、可选导出」（更可控但与用户既有配置割裂）。**倾向前者。**
- **D2｜手动新增主机是否写回 `~/.ssh/config`**：写回＝其它工具也能用、单一事实来源；不写回＝不动用户文件、更保守。推荐「默认存 Conductor 叠加层，提供显式『写回 ssh config』动作」。
- **D3｜主机簿落点 UI**：侧栏新增「Hosts」组（与 workspace 平级）还是独立面板？倾向**侧栏组**（连接是「开 pane」的入口，天然属侧栏导航；不强塞进 AgentTools 管理台——SSH 的维度不该套 Skills/MCP 那套）。

---

参考：调研覆盖 Termius / SecureCRT / Royal TSX / Asbru / WindTerm / iTerm2 / Warp / Wave / Blink / VS Code Remote 及 ProxyJump / agent-forwarding / Mosh（见本轮会话来源链接）。

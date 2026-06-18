# Agent Tools 管理台设计

## 背景

Conductor 现在右侧已经有 `CLI` 和 `用量` 面板。它们的定位不是完整后台，而是给用户快速查看状态、快速判断问题、快速进入管理动作。

完整能力不应该塞在右侧小面板里。复杂功能应该进入一个大的弹窗式管理台。这个管理台要足够完整、稳定、可商业化，统一承载各大 Agent 工具、CLI、用量、Skills、Hooks、MCP 等能力。

## 核心结论

- 右侧面板是快捷入口，不是完整管理后台。
- 大弹窗是完整 Agent Tools 管理台，承载复杂配置和批量操作。
- Skill 中心库是一级核心模块，不能变成某个 Agent 的子功能。
- Skills Manager 的功能必须完整保留，不能因为右侧空间小而删功能。
- 现在先打基础，不做 Mission Control、作战室式看板或复杂诊断中心。

## 产品结构

### 右侧面板

右侧面板负责快速查看和快速进入。

当前右侧面板包括：

- `CLI`
  - 快速查看各渠道 CLI 是否安装
  - 快速查看版本、路径、状态
  - 提供进入完整管理台的入口

- `用量`
  - 快速查看各渠道用量概览
  - 展示能真实拿到的数据
  - 提供进入完整用量详情的入口

当前右侧不再放 `Skills`、`Agents`、`Hooks`。这些都属于完整管理对象，统一进入大弹窗管理台。

### 大弹窗管理台

大弹窗是完整的 Agent Tools 管理后台。它应该是一个庞大、完善、可商业化的管理面板。

它统一管理：

- 各大渠道和 Agent 工具
- CLI 安装、路径、版本、配置
- 用量详情
- Skill 中心库
- Skill 安装、导入、Git、skills.sh、本机扫描
- Skill 标签、搜索、详情、来源更新、diff
- Skill 分发到 Codex、Claude、自定义 Agent
- Presets
- Projects
- Hooks
- MCP
- 各渠道能力支持情况
- 操作记录和基础状态

一句话：

`右侧面板 = 快速看、快速进`

`大弹窗管理台 = 完整管理、复杂操作、商业化后台`

## 大弹窗一级模块

## 大弹窗统一布局

Agent Tools 管理台使用统一三栏骨架。所有一级模块都遵循这套结构，不能只有 Skills 特殊。

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Agent Tools 管理台                                      搜索...   设置   关闭 │
├───────────────┬──────────────────────────────────────────────┬───────────────┤
│ 一级模块导航   │ 当前模块主工作区                              │ 当前选中详情    │
│               │                                              │               │
│  Overview     │  Overview 总览                                │  选中告警/工具  │
│  Tools        │  工具列表 / 能力矩阵                            │  工具详情       │
│  Usage        │  用量表 / 趋势 / 渠道筛选                        │  渠道用量详情    │
│  Skills       │  Skill 中心库 / 安装 / 分发 / Presets / Projects │  Skill 详情      │
│  Hooks        │  Hook 规则库 / 渠道部署                          │  Hook 详情       │
│  MCP          │  MCP server 列表 / 渠道启用                      │  MCP 详情        │
│  Activity     │  操作日志                                       │  日志详情        │
│               │                                              │               │
└───────────────┴──────────────────────────────────────────────┴───────────────┘
```

三栏职责：

- 左侧：一级模块导航。
- 中间：当前模块主工作区。
- 右侧：当前选中项详情和操作 inspector。

切换模块时，左侧导航保持稳定，中间和右侧内容切换。

### 各模块布局规则

#### Tools

- 中间：工具列表、能力矩阵。
- 右侧：选中工具的 CLI 路径、版本、配置目录、支持能力、启用/停用操作。

#### Agents

- 中间：Agent Registry，把启动入口、Skill 目标、运行状态和可续聊会话合并展示。
- 右侧：选中 Agent 的启动命令、CLI 路径、Skills 目录、运行 pane、会话和诊断操作。
- 详细设计见 `docs/agent-tools-agents-module-design.md`。

#### Usage

- 中间：渠道用量列表、时间筛选、模型统计。
- 右侧：选中渠道或模型的 token、成本、会话来源、原始数据入口。

#### Skills

- 中间：Skill 中心库、安装导入、分发矩阵、Presets、Projects。
- 右侧：选中 Skill、Preset 或 Project 的详情和操作。
- Skills 是深模块，内部保留 Library / Install / Workspace / Presets / Projects / Activity 二级导航。
- 详细设计见 `docs/agent-tools-skills-module-design.md`。

#### Hooks

- 中间：Hook 规则库、渠道支持情况、部署状态。
- 右侧：选中 Hook 的规则、目标渠道、启停、路径。

#### MCP

- 中间：MCP server 列表、渠道启用矩阵。
- 右侧：选中 server 的配置、状态、启用渠道、编辑操作。

#### Activity

- 中间：操作日志。
- 右侧：选中日志的完整详情、关联对象、路径、错误信息。

原则：

- 所有模块共用同一套管理台骨架。
- Skills 只是信息量最大，不是布局特例。
- 右侧 inspector 永远跟随当前选中对象。
- 没有选中对象时，右侧展示当前模块的说明、快捷动作或空态。

### 1. Overview

Overview 是管理台首页。它不是复杂诊断中心，也不是 Mission Control；它的职责是让用户在 5 秒内知道：

- 本机装了哪些 Agent CLI
- 哪些账号渠道已经可取数
- 最近用量是否正常
- 哪些能力入口可以继续管理
- 当前有没有必须处理的基础问题

#### Overview 信息架构

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Overview                                                            │
│ [搜索工具/渠道/能力]                            [重新扫描] [刷新用量] │
├─────────────────────────────────────────────────────────────────────┤
│ Status Strip                                                        │
│  CLI 已安装 8   渠道已配置 12   用量已取数 5   待处理 2             │
├─────────────────────────────────────────────────────────────────────┤
│ Capability Matrix                                                   │
│  工具/渠道        CLI   凭证   Usage   Skills   Hooks   MCP          │
│  Codex            ✓     ✓      ✓       ✓        ✓       -            │
│  Claude           ✓     ✓      ✓       ✓        ✓       -            │
│  Gemini           ✓     -      ✓       -        -       -            │
├─────────────────────────────────────────────────────────────────────┤
│ Recent / Quick Actions                                              │
│  最近扫描、最近刷新、最近错误、快捷入口                               │
└─────────────────────────────────────────────────────────────────────┘
```

#### Overview 中间工作区

上方是状态条，使用真实数据：

- `CLI 已安装`：来自 `AgentCatalog.detectStatuses()` / `CLIDetectionStore`
- `CLI 未检测到`：同上
- `渠道已配置`：来自 `UsageProviderCatalog` + `UsageCredentials.isVisible`
- `用量已取数`：来自 provider 的 `ToolUsageState.loaded`
- `用量待刷新`：来自 `ToolUsageState.manual`
- `用量错误`：来自 `ToolUsageState.error`
- `最近会话统计`：来自 `UsageReportStore` / `UsageScanner`

中间是能力矩阵。行是工具或渠道，列是能力：

- `CLI`：是否检测到可执行文件
- `凭证`：是否检测到登录态/API key/Cookie/本机配置
- `Usage`：是否支持账号用量查询
- `Skills`：是否能作为 Skill 分发目标
- `Hooks`：是否支持 hook 安装/部署
- `MCP`：是否支持 MCP 配置分发

矩阵不做假支持。未知能力显示 `未知` 或 `-`，不显示绿色成功。

下方是最近状态：

- 最近 CLI 扫描时间
- 最近用量刷新时间
- 最近失败 provider
- 最近一次本机会话统计生成时间
- 入口卡：打开 CLI、打开用量、打开 Skills、打开 Hooks、打开 MCP

#### Overview 右侧 Inspector

未选中时显示：

- 当前数据的新鲜度
- 哪些数据来自缓存
- 哪些动作会联网
- 哪些动作只读本机文件

选中某行工具/渠道时显示：

- 工具名称、logo、类别
- CLI 路径 / 版本
- 凭证状态
- 用量支持状态
- Skills/Hooks/MCP 支持状态
- 快捷动作：打开 CLI 详情、打开用量详情、复制诊断信息

#### Overview 交互

- 点击状态条数字：跳到对应筛选后的 CLI 或 Usage 模块。
- 点击矩阵行：右侧 Inspector 显示该工具/渠道详情。
- 双击矩阵行：进入对应模块详情页。
- 右键矩阵行：
  - 打开 CLI 详情
  - 打开用量详情
  - 复制诊断信息
  - 重新检测这个工具
  - 刷新这个渠道用量（仅已配置且支持）

#### Overview 不做

- 不做复杂诊断中心。
- 不做自动修复建议流。
- 不做虚假健康分。
- 不在没有真实数据时画趋势图。
- 不自动请求账号用量；只允许用户手动刷新。

### 2. CLI

CLI 模块管理 Codex、Claude、Gemini、Cursor、自定义 Agent 等本机命令行工具。它回答两个问题：

- 本机能启动哪些 Agent 工具？
- 每个工具具备哪些能力、路径和配置入口？

CLI 模块不等于用量模块。账号额度和消费趋势在 `Usage`，这里只展示和工具安装、启动、能力适配相关的信息。

#### CLI 中间工作区

```text
┌─────────────────────────────────────────────────────────────────────┐
│ CLI                                                                 │
│ [搜索 CLI / path / version] [全部|已安装|未检测|自定义] [重新扫描]    │
├─────────────────────────────────────────────────────────────────────┤
│ Tools Table                                                         │
│  Logo  名称          命令          状态      版本       能力          │
│  ●     Codex CLI     codex         已安装    0.x        Usage Skill Hook │
│  ●     Claude Code   claude        已安装    2.x        Usage Skill Hook │
│  ○     Gemini CLI    gemini        未检测    -          Usage          │
├─────────────────────────────────────────────────────────────────────┤
│ Custom / Missing / Diagnostics                                      │
└─────────────────────────────────────────────────────────────────────┘
```

主视图使用表格或紧凑列表，不使用一堆大卡片。字段包括：

- logo
- 名称
- 命令
- 安装状态
- 版本
- 可执行文件路径
- 路径来源：PATH / 常见目录 / 手动覆盖 / 未检测到
- 是否可启动
- 关联 provider
- 能力标签：Usage / Skills / Hooks / MCP
- 最近检测时间

筛选包括：

- 全部
- 已安装
- 未检测到
- 已配置凭证
- 支持 Skills
- 支持 Hooks
- 支持 Usage
- 自定义 Agent

排序包括：

- 安装状态
- 名称
- 最近检测时间
- 能力完整度

#### CLI 右侧 Inspector

选中工具后显示：

- 工具基本信息：logo、名称、命令、版本
- 安装信息：路径、PATH 命中、安装根目录
- 配置入口：配置目录、Skills 目录、Hooks 配置路径
- 关联账号渠道：是否有 provider、凭证状态、用量支持
- 能力矩阵：Skills / Hooks / MCP / Usage 是否支持
- 最近检测结果：成功/失败、错误原因

操作区：

- 启动到新标签
- 复制命令
- 复制路径
- Finder 显示
- 打开配置目录
- 重新检测这个工具
- 设置手动路径
- 清除手动路径
- 禁用/启用这个工具在启动菜单中出现

#### CLI 右键菜单

工具行右键必须有：

- 启动
- 复制命令
- 复制路径
- Finder 显示
- 打开配置目录
- 打开 Skills 目录（支持时）
- 打开 Hooks 配置（支持时）
- 重新检测
- 复制诊断信息

多选时支持：

- 重新检测选中项
- 批量隐藏/显示
- 批量复制诊断信息

#### CLI 自定义 Agent

管理台要给自定义 Agent 留入口，不要求第一版完全实现，但设计必须容纳：

- 自定义名称
- 命令
- logo 或 fallback icon
- 手动路径
- 配置目录
- Skills 目录
- 支持能力勾选
- 是否显示在新标签 Agent 菜单

#### CLI 动画与状态

- 扫描时表格行显示轻量 progress，不整页遮罩。
- 新检测到工具时行淡入并短暂高亮。
- 状态从未检测到变已安装时使用颜色和徽标过渡。
- Inspector 跟随选中项滑入，不用硬切。
- 所有图标按钮必须有 hover tooltip。

### 3. Usage

Usage 模块必须把两类用量分清楚：

1. `本机会话统计`：扫描 Claude / Codex 本机会话日志，统计 token、模型、项目、估算成本。
2. `账号额度/渠道用量`：对接各 provider 的账号 API、Cookie、本机登录态或云厂商凭证，展示额度、重置时间、计划、余额和历史采样。

这两个都叫用量，但数据来源和可信度完全不同，UI 必须明确区分。

#### Usage 中间工作区

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Usage                                                               │
│ [本机会话] [账号额度] [趋势]          [7天|30天|90天|自定义] [刷新]  │
├─────────────────────────────────────────────────────────────────────┤
│ Summary                                                             │
│ 今日成本   30天成本   总 Token   会话数   已配置渠道   待刷新渠道     │
├─────────────────────────────────────────────────────────────────────┤
│ 本机会话：日趋势 / Token 构成 / 来源 / 项目 / 模型                    │
│ 账号额度：provider 表格 / 窗口进度 / 计划 / 重置 / 错误               │
│ 趋势：本地采样历史 / provider 对比 / 高水位                           │
└─────────────────────────────────────────────────────────────────────┘
```

顶部控制：

- 时间范围：7 / 30 / 90 / 自定义
- 来源：全部 / Claude Code / Codex / provider
- 数据面：本机会话 / 账号额度 / 趋势
- 刷新按钮：
  - 本机会话刷新：扫描本地日志，不联网
  - 账号额度刷新：只刷新用户选中的 provider 或明确点击的范围

#### 本机会话统计

使用现有 `UsageScanner` / `UsageReportStore`：

- 今日成本
- 区间成本
- 总 token
- 输入 / 输出 / 缓存写 / 缓存读
- 会话数
- 活跃天数
- 每日堆叠图
- 来源分布：Claude Code / Codex
- 按项目
- 按模型

点击行为：

- 点击某天：Inspector 展示当天来源、token、成本。
- 点击项目：Inspector 展示项目路径、来源拆分、模型列表、复制路径。
- 点击模型：Inspector 展示模型价格估算、token 构成、来源。

右键菜单：

- 复制当天摘要
- 复制项目路径
- 在 Finder 显示项目
- 只看这个项目
- 只看这个模型
- 清除筛选

#### 账号额度/渠道用量

使用现有 `UsageProviderCatalog` / `UsageCredentials` / `UsageSnapshot` / `UsageHistoryStore`。

Provider 表格字段：

- logo
- provider 名称
- 类别：CLI / API / Browser Cookie / Cloud / Local Sign-in
- 状态：未配置 / 待刷新 / 刷新中 / 已取数 / 错误 / 已隐藏
- 计划名
- 账号标识
- 主窗口使用率
- 次窗口使用率
- cost / balance
- 重置时间
- 最近刷新时间

Provider 行操作：

- 刷新
- 打开配置
- 启用/隐藏
- 复制 provider ID
- 复制诊断信息
- 打开账单页（有外部链接时）

多选操作：

- 刷新选中 provider
- 启用/隐藏选中 provider
- 开启/关闭历史采样
- 批量复制配置状态

#### Usage 右侧 Inspector

未选中时显示：

- 数据来源说明
- 最近本地扫描时间
- 最近账号刷新时间
- 当前筛选条件
- 账号刷新不会自动发生的提示

选中 provider 时显示：

- provider 名称、类别、logo
- 凭证来源：API key / Cookie / 浏览器 / 本机登录 / 云厂商
- 支持的配置字段
- 当前状态和错误详情
- `UsageSnapshot` 全量信息：
  - primary / secondary / tertiary window
  - extraRateWindows
  - providerCost
  - planName
  - accountLabel
  - updatedAt
- 历史采样趋势
- 操作：
  - 刷新
  - 打开配置
  - 复制诊断
  - 打开外部账单页
  - 隐藏渠道

选中本机会话对象时显示：

- 天 / 项目 / 模型 / 来源的上下文详情
- token 构成
- 估算成本说明
- 来源日志类型
- 可复制摘要

#### Usage 原则

- 不自动请求账号接口。
- 不展示假数据。
- 没有凭证时显示 `未配置`，不要显示 0。
- 没有 provider 支持某项用量时显示 `暂不支持`。
- 成本估算必须标注来源和不确定性。
- 所有凭证展示都必须脱敏。
- 错误信息要能复制，但不能泄漏 token。

### 4. Skills

完整 Skills Manager。这里必须保留所有核心功能。

Skills 的核心架构是：

`Skill 中心库 = source of truth`

`Agent / 渠道 = deployment target`

不能变成：

`Agent Tool -> 自己的一小堆 Skills`

#### Skill 中心库

中心库必须保留：

- 所有已管理 Skills
- 搜索
- 标签
- 来源类型
- 来源路径
- Git / skills.sh / local 元数据
- 同步状态
- 更新状态
- 右键菜单
- 批量选择
- 删除
- 导出

#### 安装和导入

必须支持：

- skills.sh 市场
- Git 仓库预览
- Git 多 Skill 子路径选择
- 本地目录导入
- zip / bundle 导入
- 本机扫描
- 批量导入扫描结果

#### Skill 详情

必须支持：

- SKILL.md 预览
- 文件列表
- 文件画像
- 来源信息
- 更新检查
- 来源刷新
- diff 预览
- 操作入口

#### 分发

必须支持：

- 中心库 Skill 分发到 Codex
- 中心库 Skill 分发到 Claude
- 中心库 Skill 分发到自定义 Agent
- 软链模式
- 复制模式
- 单个 Skill 同步
- 批量同步
- 移除同步
- 同步状态展示
- 失败状态展示

#### Presets

必须支持：

- 创建 Preset
- 删除 Preset
- 添加 Skill 到 Preset
- 移出 Skill
- Skill 排序
- 一键应用 Preset
- 移除 Preset 同步

#### Projects

必须支持：

- 添加项目目录
- 项目级 Skills
- 应用 Preset 到项目
- 中心库 Skill 同步到项目
- 查看项目实际存在的 Skills
- 移除项目同步

#### Activity

必须记录：

- 导入
- 安装
- 同步
- 移除同步
- 删除
- 标签变更
- Preset 操作
- Project 操作
- 来源刷新
- 更新检查

### 5. Hooks

Hooks 是完整管理台中的基础模块。

原则：

- 支持的渠道展示配置入口
- 不支持的渠道明确不可用
- 先做基础管理，不做复杂自动化编排

基础能力：

- 查看 Hooks
- 新增 Hook
- 启用 / 停用
- 按渠道部署
- 删除
- 查看配置路径

### 6. MCP

MCP 是完整管理台中的基础模块。

原则：

- 全局 MCP registry
- 按渠道启用
- 不支持的渠道明确不可用

基础能力：

- 查看 MCP servers
- 新增 server
- 编辑配置
- 启用 / 停用
- 按渠道分发配置
- 删除

## 右侧面板和大弹窗的关系

右侧面板只做：

- 快速状态
- 快速搜索
- 最近项
- 当前项简略详情
- 快速进入完整管理台

当前右侧保留：

- `CLI`
- `用量`
- `片段`

右侧面板不做：

- 完整 Skill Manager
- 完整 Agent 管理
- 完整 Preset 管理
- 完整 Project 管理
- 完整 Hooks 管理
- 完整 MCP 管理
- 大量横向卡片堆叠

`Skills`、`Agents`、`Hooks`、`MCP` 不再作为右侧分段出现。旧入口或命令如果指向这些模块，应该直接 deep link 到 Agent Tools 管理台。

## 管理台入口

Agent Tools 管理台需要两层入口：全局主入口和右侧面板内的上下文入口。

### 全局主入口

在应用右上角增加一个入口，和设置、主题、通知等全局按钮并列。

建议名称：

- `Agent Tools`
- 或中文 `工具管理`

建议图标：

- `cpu`
- `terminal.badge.gearshape`
- `slider.horizontal.3`

点击后打开完整 Agent Tools 管理台大弹窗，默认进入 `Overview`。

原因：

- Agent Tools 管理台不是 CLI 面板的子功能。
- Agent Tools 管理台也不是 Skills、Hooks、MCP 的子功能。
- 它是全局管理后台，应该有全局入口。
- 如果只放在右侧 CLI / 用量面板里，用户不打开这些面板就找不到完整管理台。

### 右侧面板上下文入口

右侧 `CLI` 面板顶部增加一个管理入口：

- 文案：`打开工具管理`
- 或 icon button：`slider.horizontal.3`

点击后打开同一个 Agent Tools 管理台，但 deep link 到 `CLI` 模块。

右侧 `用量` 面板顶部增加一个管理入口：

- 文案：`打开用量详情`
- 或 icon button：`chart.bar.doc.horizontal`

点击后打开同一个 Agent Tools 管理台，但 deep link 到 `Usage` 模块。

`Skills`、`Agents`、`Hooks`、`MCP` 只从全局管理台入口、命令面板或其它上下文 deep link 打开，不再塞回右侧面板。

### 入口总结

- 右上角按钮：打开完整管理台首页
- CLI 面板按钮：打开管理台 `CLI`
- 用量面板按钮：打开管理台 `Usage`
- 旧 Skills / Agents / Hooks 入口：直接打开管理台对应模块

## 实现原则

- 不删功能，只归位。
- 大功能进入大弹窗，小面板只做快捷入口。
- Skill 中心库永远是一级资产。
- Agent 工具是分发目标和能力适配器。
- 不支持的能力要明确显示，不要假装支持。
- 先做基础能力，再做高级诊断。
- UI 统一，但不能用统一为理由砍功能。

## 当前优先级

1. 恢复并稳定完整 Skills Manager。
2. 将右侧 Skills / Agents / Hooks 全部迁到管理台。
3. 建立 Agent Tools 大弹窗壳。
4. 把 CLI、Usage、Skills 作为第一批模块接入。
5. 再接 Hooks 和 MCP 的基础管理。
6. 暂缓 Mission Control 和复杂诊断中心。

## 第一阶段落地：Overview / CLI / Usage

这三块先做，因为它们已经有真实数据和现有右侧面板能力，可以最快把管理台从空壳变成可用后台。

### 共享数据层

需要抽一个管理台级 store，避免 Overview、CLI、Usage 各自重复扫描：

- `AgentToolsConsoleStore`
  - CLI statuses：来自 `AgentCatalog.detectStatuses()` 和 `CLIDetectionStore`
  - provider entries：来自 `UsageProviderCatalog.all`
  - provider states：沿用 `ToolUsageState`
  - usage reports：来自 `UsageReportStore` / `UsageScanner`
  - usage history：来自 `UsageHistoryStore`
  - selected object：工具、provider、day、project、model

加载原则：

- 打开管理台先读缓存。
- CLI 扫描由用户触发，或者无缓存时触发一次。
- 本机会话统计可读缓存，刷新由用户触发。
- 账号 provider 不自动发网络请求，只检测本地可用性；真实用量必须用户点击刷新。

### 里程碑 1：Overview 可用首页

交付：

- 状态条使用真实计数。
- 能力矩阵先覆盖 CLI / 凭证 / Usage。
- 点击矩阵行可更新 Inspector。
- 点击状态条可跳转到 CLI 或 Usage。
- 右键提供复制诊断信息。

不做：

- 不接复杂诊断中心。
- 不接自动修复。
- 不画没有数据来源的趋势。

验收：

- 没有 CLI 缓存时不崩。
- 没有 provider 凭证时显示待配置。
- 所有按钮有 tooltip。
- 右侧 Inspector 不空白。

### 里程碑 2：CLI 完整管理

交付：

- CLI 表格替代空态。
- 搜索、筛选、排序。
- 工具详情 Inspector。
- 启动、复制路径、Finder、重新检测。
- 旧 `.skills/.agents/.hooks` 入口不再打开右侧面板。

延后：

- 自定义 Agent 编辑器可以先放入口和空态。
- 手动 path override 可作为第二步做。

验收：

- 已安装和未检测工具都能显示。
- 版本和路径长文本不挤爆布局。
- 单行 hover、选中、右键行为统一。
- 扫描过程中不锁死整个管理台。

### 里程碑 3：Usage 双数据面

交付：

- `本机会话统计`：复用现有 UsageStats 数据，迁到管理台大空间。
- `账号额度`：复用 UsageProvidersSettings 的 provider 列表和详情能力。
- provider Inspector 展示 `UsageSnapshot` 全量信息。
- 支持刷新单个 provider。
- 支持刷新选中 provider。
- 显示历史采样趋势。

延后：

- 自定义时间范围。
- 批量导出 CSV。
- 预算告警。

验收：

- 本地扫描和账号刷新文案明确区分。
- 没有凭证的 provider 不显示 0，用 `待配置`。
- 错误可复制，token 不泄漏。
- 切换 7 / 30 / 90 天不会影响账号额度列表。

### 组件要求

- 三个模块共用同一套空态、表格行、状态徽标、toolbar、Inspector Section。
- 图标按钮必须使用 `IconOnlyButton` 或等价带 tooltip 的组件。
- 表格和 Inspector 切换要有轻量动画。
- 页面不能依赖窄右侧布局；管理台按大弹窗空间设计。
- 不用解释型大段文案占空间，信息要能扫读。

# Agent Tools Skills 模块设计

## 目标

Skills 是 Agent Tools 管理台的一等模块，不是右侧小面板，也不是某个 Agent 的附属页。

这个模块的目标是完整承载 skillmanager 的核心能力：

- 中央库：统一收纳、搜索、筛选、标签、详情。
- 安装：skills.sh、Git、本地导入、本机扫描。
- 分发：同步到 Codex、Claude、自定义 Agent 等可接收目标。
- Presets：把一组 Skills 做成可复用分组。
- Projects：项目级 Skills 和本地项目目录同步。
- Agents：展示可接收 Skills 的工具目标。
- Activity：导入导出、bundle 迁移、操作记录。

第一原则：不能因为右侧空间小或管理台还在搭骨架，就删掉这些功能。

## 信息架构

Agent Tools 管理台有一级模块导航，Skills 内部再有自己的二级深导航。

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Agent Tools 管理台                                                           │
├───────────────┬──────────────────────────────────────────────┬───────────────┤
│ 一级模块导航   │ Skills 工作区                                  │ Skills 汇总    │
│               │ ┌──────────────┬────────────────────────────┐ │               │
│  Overview     │ │ Skills 二级导航│ 当前 Skills 分区             │ │ 中央库数量      │
│  CLI          │ │ Library       │ Library / Install / Deploy │ │ 可接收目标      │
│  Usage        │ │ Install       │ Presets / Projects / Logs  │ │ 未同步数量      │
│  Agents       │ │ Workspace     │                            │ │ 来源异常        │
│  Skills       │ │ Presets       │                            │ │ 快捷跳转        │
│  MCP          │ │ Projects      │                            │ │ 状态复制        │
│  Hooks        │ │ Activity      │                            │ │               │
└───────────────┴──────────────────────────────────────────────┴───────────────┘
```

这样做的原因：

- 外层导航负责跨模块切换。
- Skills 本身信息量很大，需要自己的二级导航。
- 右侧 inspector 只做模块级汇总和跨模块动作，不抢 Skill 详情面板的职责。
- Skill 详情仍由 Skills workbench 内部弹窗承载，因为那里有文件、来源 diff、目标同步、标签和危险操作。

## 中间工作区

中间工作区直接承载完整 Skills workbench。

分区职责：

- `Library`：中央库主列表，支持搜索、来源筛选、标签筛选、网格/列表视图、批量选择、右键菜单、打开详情、同步、检查更新、刷新来源、Reveal、删除。
- `Install`：skills.sh 市场、Git 预览安装、本地导入、本机扫描。
- `Workspace`：按 Agent 目标查看已同步 Skills、未同步 Skills、同步模式。
- `Presets`：创建、展开、应用、删除可复用 Skill 分组。
- `Projects`：项目记录、项目目标、项目级 Skill 同步。
- `Agents`：Skill 目标工具启停、目录状态、自定义目标。
- `Activity`：导入导出、bundle、操作日志。

## 右侧 Inspector

管理台右侧 inspector 只回答这些模块级问题：

- 中央库里有多少 Skills。
- 有多少 Agent 目标可以接收 Skills。
- 已经同步了多少目标记录。
- 有多少 Skills 还没同步。
- 有多少来源异常或可更新。
- 来源类型分布和目标分布。
- 快捷进入 Library、Install、Workspace、Presets、Projects、Agents。
- 复制 Skills 状态摘要。

它不承载单个 Skill 的完整编辑，因为完整编辑需要文件、diff、标签、目标矩阵和危险操作，应该留在 workbench 的详情面板里。

## 实现阶段

### 阶段 1：接入完整 workbench

- 在 Agent Tools 管理台的 `Skills` 模块中嵌入 `SkillsManagerView(presentationMode: .workbench)`。
- 外层 inspector 从 `AgentToolsConsoleStore` 读取 `SkillManagerEngine` 快照。
- inspector 提供汇总、快捷跳转、复制状态摘要。
- 不删现有 SkillsManagerView 的任何功能。

### 阶段 2：统一外观

- 把 Skills workbench 的表面、按钮、空态和详情弹窗逐步迁移到管理台基础组件。
- 保留二级导航，但让它看起来像管理台内部导航，而不是另一个孤立弹窗。
- 弱化重分割线和重边框，改成一体化背景、轻表面、清晰 hover。

### 阶段 3：增强管理能力

- 批量标签编辑。
- 保存筛选视图。
- 更明确的目标分发矩阵。
- 来源更新队列。
- 安装任务历史。
- Skill 与 Agent 能力兼容提示。

## 非目标

- 不做诊断优先页面。
- 不把 Skills 压回右侧面板。
- 不把中心库藏到 Agent 子页。
- 不删除 skills.sh、Git、本地导入、扫描、Presets、Projects、Activity 等能力。

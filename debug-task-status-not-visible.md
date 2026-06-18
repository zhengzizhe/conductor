# Debug Session: task-status-not-visible
- **Status**: [OPEN]
- **Issue**: 打开应用后，看不到标签页、左侧会话列表或左侧工作区的任务状态展示，实际表现与预期不符。
- **Debug Server**: http://127.0.0.1:7777/event
- **Log File**: .dbg/trae-debug-log-task-status-not-visible.ndjson

## Reproduction Steps
1. 打开 `Conductor.app`
2. 进入任意存在会话/任务的工作区
3. 观察顶部标签页、左侧会话列表、左侧工作区左下状态区域
4. 当前未看到任务中、完成或异常状态展示

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | 任务状态数据根本没有进入 `AppCoordinator` 的展示层状态集合 | High | Low | Pending |
| B | 状态数据已存在，但 `TabBarView` / `SidebarView` 没有正确渲染或被 hover/布局条件隐藏 | High | Low | Pending |
| C | 只有“真实运行中的 Agent 任务”才会显示状态，而当前打开的 app 并没有触发这种任务源 | Medium | Low | Pending |
| D | 左侧工作区状态区域已实现，但布局位置或命中区域错误，导致肉眼看不到或无法点击 | Medium | Medium | Pending |
| E | 当前本地运行的 app 不是包含这些改动的构建产物，或者运行的是旧状态数据 | Medium | Low | Pending |

## Log Evidence
- 2026-06-12：已在 `AppCoordinator` 添加最小埋点，记录 hook 事件入口、thinking 集合发布、tab 状态计算、工作区状态条计算、pane 异常退出。

## Verification Conclusion
- Pending

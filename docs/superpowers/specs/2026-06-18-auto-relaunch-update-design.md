# Conductor 自动安装并重启更新设计

日期：2026-06-18

## 背景

现有更新入口已经能从 GitHub Releases 检查版本并下载对应架构的 DMG，但下载完成后仍要求用户手动打开 DMG、拖拽 `Conductor.app` 到 Applications 并替换旧版本。这个步骤繁琐，也容易让用户在旧版本继续运行。

## 支持结论

未加入 Apple Developer 也可以支持“下载完成后提示是否重启；重启则立即替换并打开新版；稍后则在退出后替换，下次打开就是新版”的主流程，但有两个 macOS 约束不能绕过：

- 未公证或带 quarantine 标记的 App 首次打开时，Gatekeeper 仍可能要求用户确认。
- 如果当前安装位置不可由当前用户写入，替换 `.app` 会失败，需要用户改用手动安装或调整权限。

因此本次实现采用用户触发的一键安装，而不是后台静默更新。

## 方案

下载完成后，App 弹出确认框询问是否现在重启并安装：

1. 选择“重启并安装”时，`ConductorApp` 根据当前 bundle 找到自身 `.app` 路径和内置 `ConductorUpdater` helper。
2. 主 App 启动 helper，传入 DMG 路径、目标 `.app` 路径、bundle id 和 `--reopen true`。
3. 主 App 退出，释放正在运行的可执行文件。
4. helper 挂载 DMG，寻找其中的 `.app`。
5. helper 等待旧 App 进程退出，备份旧 `.app`，用 DMG 中的新 `.app` 替换目标路径。
6. helper 卸载 DMG，并用 `open` 重新打开目标 `.app`。
7. 选择“稍后”时，App 记录 pending update；用户之后退出 Conductor 时，App 启动 helper 并传入 `--reopen false`，helper 替换 `.app` 但不重新打开，保证下次手动打开就是新版。

UI 保留“打开安装包”和“在访达中显示”作为兜底。

## 模块边界

- `UpdateInstallerPlan`：App 内可测试的安装计划，负责解析当前 `.app`、helper 路径和启动参数。
- `PendingUpdateStore`：记录“稍后安装”的 DMG 路径和版本。
- `UpdateManager`：负责下载完成后的确认提示、pending update 记录、启动 helper 和触发退出，不直接执行文件替换。
- `ConductorUpdater`：独立 SwiftPM executable，负责 DMG 挂载、等待退出、替换，并按 `--reopen` 决定是否重开。
- 打包脚本：构建、复制、签名 `ConductorUpdater`，保证发布包内可用。

## 验收

- `swift build` 通过。
- `swift test --filter UpdateInstallerPlanTests` 在具备 XCTest 的本机工具链上通过。
- 打包后的 `Conductor.app/Contents/MacOS/ConductorUpdater` 存在且可执行。
- 下载更新后，确认框选择“重启并安装”能完成退出、替换和重新打开。
- 下载更新后，确认框选择“稍后”能在 App 退出后替换 `.app`，下次打开就是新版。
- 若权限不足，保留手动安装路径。

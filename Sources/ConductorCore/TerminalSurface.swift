import Foundation

/// 一个终端实例的引擎无关生命周期接口。生产实现是 GhosttySurface（app 层，封装 libghostty）；
/// 测试用 FakeSurface。输入/渲染/尺寸由具体实现在视图层处理，不属于本协议。
@MainActor
public protocol TerminalSurface: AnyObject {
    /// 在给定工作目录启动 shell/PTY。
    func start(cwd: URL)
    /// 使该终端获得键盘焦点。
    func focus()
    /// 关闭终端并释放底层资源。
    func close()

    /// 终端标题变化回调。
    var onTitleChange: ((String) -> Void)? { get set }
    /// 终端工作目录变化回调。
    var onCwdChange: ((URL) -> Void)? { get set }
    /// 进程退出回调，参数为退出码。
    var onExit: ((Int32) -> Void)? { get set }
}

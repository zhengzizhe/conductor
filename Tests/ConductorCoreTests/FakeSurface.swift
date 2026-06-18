import Foundation
@testable import ConductorCore

/// TerminalSurface 的测试替身：记录调用，并允许测试手动触发回调。
@MainActor
final class FakeSurface: TerminalSurface {
    private(set) var startedCwd: URL?
    private(set) var focusCount = 0
    private(set) var closed = false

    var onTitleChange: ((String) -> Void)?
    var onCwdChange: ((URL) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(cwd: URL) { startedCwd = cwd }
    func focus() { focusCount += 1 }
    func close() { closed = true }

    func simulateTitleChange(_ title: String) { onTitleChange?(title) }
    func simulateCwdChange(_ url: URL) { onCwdChange?(url) }
    func simulateExit(_ code: Int32) { onExit?(code) }
}

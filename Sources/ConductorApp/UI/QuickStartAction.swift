import SwiftUI

struct QuickStartAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// 符号化键位（如「⌘T」）；有则作为键帽展示，无则回退到 systemImage。
    let shortcut: String?
    let isPrimary: Bool
    let run: () -> Void

    init(id: String, title: String, systemImage: String, shortcut: String? = nil, isPrimary: Bool = false, run: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isPrimary = isPrimary
        self.run = run
    }
}

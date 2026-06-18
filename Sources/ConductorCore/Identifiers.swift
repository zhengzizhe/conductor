/// 一个终端 pane（分屏叶子）的稳定标识。
public struct PaneID: Hashable, Codable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// 一个 Tab 的稳定标识。
public struct TabID: Hashable, Codable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// 一个工作区的稳定标识。
public struct WorkspaceID: Hashable, Codable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// 一次分屏（分隔条）的稳定标识，用于定位并调整其比例。
public struct SplitID: Hashable, Codable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

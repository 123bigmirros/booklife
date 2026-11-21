import Foundation

public enum ReadingMode: String, Codable, CaseIterable {
    case scroll, paged
    public var title: String { self == .scroll ? "连续滚动" : "分页阅读" }
    public var nextLabel: String { self == .scroll ? "向下滚动" : "下一页" }
    public var previousLabel: String { self == .scroll ? "向上滚动" : "上一页" }
}

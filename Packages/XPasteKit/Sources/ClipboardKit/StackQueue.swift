import Foundation

/// Stack 的队列：保存的就是窗口里从上到下的顺序，也是粘贴的顺序；每次 ⌘V 取走最上面一行。
///
/// 新复制的放在哪一头与原版实测一致（Docs/归档/调研/08 第 9.18 节）：默认放最上面，后复制的先粘；
/// 反转后整列翻过来，新复制的改接在最下面。改版后（Docs/归档/验收记录/Stack改版.md）行可以拖动排序、单独取走、放回原位。
public struct StackQueue<Element> {
    /// 从上到下的显示顺序。
    public private(set) var items: [Element] = []
    /// 新复制的接在最下面（先复制的先粘）。默认 false：放最上面。
    public private(set) var isReversed: Bool

    public init(isReversed: Bool = false) {
        self.isReversed = isReversed
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// 窗口里从上到下的显示顺序，也是粘贴的顺序。
    public var displayed: [Element] { items }

    /// 复制来的一项。相同内容也不合并。
    public mutating func collect(_ element: Element) {
        collect(contentsOf: [element])
    }

    /// 一组按给定顺序整组放进去（从面板加入的选中项按面板顺序），放在哪一头同 `collect`。
    public mutating func collect(contentsOf elements: [Element]) {
        isReversed ? items.append(contentsOf: elements) : items.insert(contentsOf: elements, at: 0)
    }

    /// 最上面一行（下一次要粘的），不取走。
    public var next: Element? { items.first }

    /// 取走最上面一行；队列为空时返回 nil。
    public mutating func takeNext() -> Element? {
        items.isEmpty ? nil : items.removeFirst()
    }

    @discardableResult
    public mutating func remove(at index: Int) -> Element {
        items.remove(at: index)
    }

    /// 放回某个位置；超出范围时放到最下面。
    public mutating func insert(_ element: Element, at index: Int) {
        items.insert(element, at: min(max(index, 0), items.count))
    }

    /// 把一行挪到 `destination`（挪完之后它所在的位置）。
    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let element = items.remove(at: source)
        items.insert(element, at: min(max(destination, 0), items.count))
    }

    /// 整列翻过来，之后新复制的接到另一头。
    public mutating func reverse() {
        items.reverse()
        isReversed.toggle()
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}

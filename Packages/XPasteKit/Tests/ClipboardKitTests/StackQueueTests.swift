import Testing
@testable import ClipboardKit

@Suite struct StackQueueTests {
    @Test func defaultOrderPastesNewestFirst() {
        var queue = StackQueue<String>()
        for item in ["one", "two", "three"] { queue.collect(item) }
        #expect(queue.displayed == ["three", "two", "one"])
        #expect(queue.takeNext() == "three")
        // 途中又复制了一条：它排到最上面，下一次先粘它。
        queue.collect("four")
        #expect(queue.displayed == ["four", "two", "one"])
        #expect(queue.takeNext() == "four")
        #expect(queue.takeNext() == "two")
        #expect(queue.takeNext() == "one")
        #expect(queue.takeNext() == nil && queue.isEmpty)
    }

    @Test func reversedPastesOldestFirst() {
        var queue = StackQueue<String>(isReversed: true)
        for item in ["one", "two", "three"] { queue.collect(item) }
        #expect(queue.displayed == ["one", "two", "three"])
        #expect(queue.takeNext() == "one")
        // 途中又复制了一条：它接在最下面，最后才粘。
        queue.collect("four")
        #expect(queue.displayed == ["two", "three", "four"])
        #expect(queue.takeNext() == "two")
    }

    /// `next` 只看不取，和 `takeNext` 取到的是同一项（写剪贴板失败时队列不推进，审查 01）。
    @Test func nextPeeksWithoutRemoving() {
        for reversed in [false, true] {
            var queue = StackQueue<String>(isReversed: reversed)
            #expect(queue.next == nil)
            for item in ["one", "two", "three"] { queue.collect(item) }
            let peeked = queue.next
            #expect(queue.count == 3)
            #expect(queue.takeNext() == peeked)
        }
    }

    /// 反转把现有的整列翻过来，之后新复制的接到另一头；再反转回到原样。
    @Test func reversingFlipsItemsAndWhereCopiesGo() {
        var queue = StackQueue<String>()
        for item in ["one", "two", "three"] { queue.collect(item) }
        queue.reverse()
        #expect(queue.isReversed && queue.displayed == ["one", "two", "three"])
        queue.collect("four")
        #expect(queue.displayed == ["one", "two", "three", "four"])
        queue.reverse()
        #expect(!queue.isReversed && queue.displayed == ["four", "three", "two", "one"])
        queue.collect("five")
        #expect(queue.next == "five")
    }

    /// 从面板加入的一组保持面板顺序，整组放到新内容该去的那一头。
    @Test func groupsKeepTheirOrder() {
        var queue = StackQueue<String>()
        queue.collect("copied")
        queue.collect(contentsOf: ["a", "b", "c"])
        #expect(queue.displayed == ["a", "b", "c", "copied"])
        var reversed = StackQueue<String>(isReversed: true)
        reversed.collect("copied")
        reversed.collect(contentsOf: ["a", "b", "c"])
        #expect(reversed.displayed == ["copied", "a", "b", "c"])
    }

    @Test func movingRemovingAndPuttingBack() {
        var queue = StackQueue<String>(isReversed: true)
        queue.collect(contentsOf: ["a", "b", "c", "d"])
        queue.move(from: 0, to: 2)
        #expect(queue.displayed == ["b", "c", "a", "d"])
        queue.move(from: 3, to: 0)
        #expect(queue.displayed == ["d", "b", "c", "a"])
        let removed = queue.remove(at: 1)
        #expect(removed == "b" && queue.displayed == ["d", "c", "a"])
        queue.insert(removed, at: 1)
        #expect(queue.displayed == ["d", "b", "c", "a"])
        // 位置超出范围时放到最下面。
        queue.insert("e", at: 99)
        #expect(queue.displayed.last == "e")
        queue.move(from: 9, to: 0)
        #expect(queue.count == 5)
    }

    @Test func duplicatesAreKept() {
        var queue = StackQueue<String>()
        queue.collect("same")
        queue.collect("same")
        #expect(queue.count == 2)
    }
}

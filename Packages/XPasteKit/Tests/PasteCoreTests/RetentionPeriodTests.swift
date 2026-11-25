import Foundation
import Testing
@testable import PasteCore

/// 保留期限：2026-11-25 加了 3 个月、半年两档。设置的滑块和“缩短期限要确认”都按声明顺序比较，顺序必须从短到长。
@Suite struct RetentionPeriodTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func newPeriodsCutOffThreeAndSixMonthsBack() throws {
        let three = try #require(RetentionPeriod.threeMonths.cutoff(from: now, calendar: calendar))
        let six = try #require(RetentionPeriod.sixMonths.cutoff(from: now, calendar: calendar))
        #expect(calendar.dateComponents([.month], from: three, to: now).month == 3)
        #expect(calendar.dateComponents([.month], from: six, to: now).month == 6)
    }

    @Test func periodsAreOrderedFromShortestToLongest() {
        #expect(RetentionPeriod.allCases == [.day, .week, .month, .threeMonths, .sixMonths, .year, .forever])
        let cutoffs = RetentionPeriod.allCases.compactMap { $0.cutoff(from: now, calendar: calendar) }
        #expect(cutoffs.count == 6)
        #expect(zip(cutoffs, cutoffs.dropFirst()).allSatisfy { $0 > $1 })
        #expect(RetentionPeriod.forever.cutoff(from: now, calendar: calendar) == nil)
    }

    @Test func storedValuesStillParse() {
        // 偏好里存的是 rawValue，原有几档的值不能变。
        #expect(["day", "week", "month", "year", "forever"].compactMap(RetentionPeriod.init(rawValue:)).count == 5)
        #expect(RetentionPeriod(rawValue: "threeMonths") == .threeMonths && RetentionPeriod(rawValue: "sixMonths") == .sixMonths)
    }
}

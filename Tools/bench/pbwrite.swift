// 测量用的剪贴板写入程序：按固定间隔往命名剪贴板写带序号和时间戳的文本，只碰传入名字的剪贴板。
// 用法：pbwrite <剪贴板名> <轮次> <条数> <间隔毫秒>
// 每条内容是 "xpaste-bench <轮次> <序号> <CLOCK_UPTIME_RAW 纳秒>"，XPaste 的测量模式据此算采集延迟。
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 5, !arguments[1].isEmpty, arguments[1] != NSPasteboard.Name.general.rawValue,
      let run = Int(arguments[2]), let count = Int(arguments[3]), let gap = UInt64(arguments[4]) else {
    FileHandle.standardError.write(Data("用法：pbwrite <剪贴板名> <轮次> <条数> <间隔毫秒>\n".utf8))
    exit(2)
}
let pasteboard = NSPasteboard(name: .init(arguments[1]))
let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
for index in 0..<count {
    // 按开始时刻排定每一条的写入时间，不让写入本身的耗时累积成漂移。
    let deadline = start + UInt64(index) * gap * 1_000_000
    while case let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), now < deadline {
        usleep(useconds_t(min((deadline - now) / 1_000, 2_000)))
    }
    pasteboard.clearContents()
    pasteboard.setString("xpaste-bench \(run) \(index) \(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))", forType: .string)
}
print("WROTE \(count)")

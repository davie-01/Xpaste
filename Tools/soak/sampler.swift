// M5 第 4 步长驻采样：每隔一段时间记一行 XPaste 及其转接进程的资源，追加到 CSV。
// 只读进程计数器和数据目录的文件大小，不读剪贴板、历史内容或设置。
//
//   sampler <输出.csv> <被测程序路径> <数据目录> [间隔秒，默认 60]
//
// 进程按可执行文件路径找；不在时记一行 pid=0，重新出现后接着记。
// CPU 时间和唤醒是累计值，看曲线时取相邻两行的差。墙钟间隔远大于采样间隔说明电脑睡过。
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("用法：sampler <输出.csv> <被测程序路径> <数据目录> [间隔秒]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let appPath = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().path
let dataDir = URL(fileURLWithPath: args[3], isDirectory: true)
let interval = args.count > 4 ? max(5, Double(args[4]) ?? 60) : 60

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func allPids() -> [pid_t] {
    let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard bytes > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
    let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(used) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
}

struct Usage {
    var cpuS = 0.0, wakeups: UInt64 = 0, footprintMB = 0.0, diskWrittenMB = 0.0, threads: Int32 = 0, fds = 0
}

func usage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var result = Usage()
    let ticks = info.ri_user_time + info.ri_system_time
    result.cpuS = Double(ticks * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1e9
    result.wakeups = info.ri_pkg_idle_wkups + info.ri_interrupt_wkups
    result.footprintMB = Double(info.ri_phys_footprint) / 1_048_576
    result.diskWrittenMB = Double(info.ri_diskio_byteswritten) / 1_048_576
    var task = proc_taskinfo()
    if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
        result.threads = task.pti_threadnum
    }
    let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    if fdBytes > 0 { result.fds = Int(fdBytes) / MemoryLayout<proc_fdinfo>.size }
    return result
}

func size(_ url: URL) -> Double {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Double($0) / 1_048_576 } ?? 0
}

func assets() -> (files: Int, mb: Double) {
    guard let walker = FileManager.default.enumerator(at: dataDir.appendingPathComponent("Assets"),
                                                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, 0) }
    var files = 0, bytes = 0
    for case let url as URL in walker {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
        files += 1
        bytes += values.fileSize ?? 0
    }
    return (files, Double(bytes) / 1_048_576)
}

let header = "time,uptime_s,pid,cpu_s,wakeups,footprint_mb,disk_written_mb,threads,fds,helpers,helper_footprint_mb,db_mb,wal_mb,asset_files,asset_mb\n"
if !FileManager.default.fileExists(atPath: outPath) {
    FileManager.default.createFile(atPath: outPath, contents: header.data(using: .utf8))
}
guard let out = FileHandle(forWritingAtPath: outPath) else { exit(1) }
out.seekToEndOfFile()

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]
formatter.timeZone = .current
setvbuf(stdout, nil, _IOLBF, 0)

while true {
    let pids = allPids()
    let paths = pids.map { ($0, executablePath($0)) }
    let main = paths.first { $0.1 == appPath }?.0 ?? 0
    // 转接程序在 XPaste.app 里面，由 MCP 客户端拉起，父进程不一定是 XPaste。
    let bundle = URL(fileURLWithPath: appPath).deletingLastPathComponent().deletingLastPathComponent().path + "/"
    let helpers = paths.filter { $0.0 != main && ($0.1?.hasPrefix(bundle) ?? false) }.map(\.0)
    let u = main == 0 ? Usage() : (usage(main) ?? Usage())
    let helperFootprint = helpers.compactMap(usage).reduce(0) { $0 + $1.footprintMB }
    let a = assets()
    let line = [
        formatter.string(from: Date()), String(format: "%.0f", ProcessInfo.processInfo.systemUptime), "\(main)",
        String(format: "%.3f", u.cpuS), "\(u.wakeups)", String(format: "%.2f", u.footprintMB), String(format: "%.2f", u.diskWrittenMB),
        "\(u.threads)", "\(u.fds)", "\(helpers.count)", String(format: "%.2f", helperFootprint),
        String(format: "%.2f", size(dataDir.appendingPathComponent("db.sqlite"))),
        String(format: "%.2f", size(dataDir.appendingPathComponent("db.sqlite-wal"))),
        "\(a.files)", String(format: "%.2f", a.mb),
    ].joined(separator: ",") + "\n"
    out.write(line.data(using: .utf8)!)
    try? out.synchronize()
    Thread.sleep(forTimeInterval: interval)
}

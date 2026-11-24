"""把 Tools/bench/run.sh 的 results.jsonl 汇总成几张表。用法：python3 -I summarize.py results.jsonl"""
import json
import re
import statistics
import sys
from collections import defaultdict


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def fmt(value, digits=2):
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def spread(values, digits=2):
    """多轮结果：中位数和最小–最大。"""
    values = [v for v in values if v is not None]
    if not values:
        return "-"
    if len(values) == 1:
        return fmt(values[0], digits)
    return f"{fmt(statistics.median(values), digits)}（{fmt(min(values), digits)}–{fmt(max(values), digits)}）"


def table(title, header, rows):
    print(f"\n## {title}\n")
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for row in rows:
        print("| " + " | ".join(fmt(c) if not isinstance(c, str) else c for c in row) + " |")


def main(path):
    rows = load(path)
    results = [r for r in rows if r.get("event") == "result"]
    errors = [r for r in rows if r.get("event") == "error"]
    ends = [r for r in rows if r.get("event") == "end"]
    print(f"# 测量汇总\n\n结果 {len(results)} 条；出错 {len(errors)} 个场景；正常结束 {sum(1 for r in ends if r.get('ok'))}/{len(ends)}。")
    for e in errors:
        print(f"- 出错：{e.get('run')} {e.get('error')}")

    idle = defaultdict(list)
    for r in results:
        if r["scenario"] == "idle":
            idle[re.sub(r"-r\d+$", "", r["run"])].append(r)
    if idle:
        table("空闲（B1、B2、B12），多轮取中位数（最小–最大）",
              ["配置", "轮数", "CPU %（单核）", "唤醒/秒", "写盘 KB", "内存 MB", "线程", "句柄", "采集次数"],
              [[k, len(v), spread([r["cpu_pct_one_core"] for r in v], 3), spread([r["wakeups_per_s"] for r in v]),
                spread([r["disk_written_bytes"] / 1024 for r in v], 1), spread([r["footprint_mb"] for r in v], 1),
                spread([r["threads"] for r in v], 0), spread([r["fds"] for r in v], 0), spread([r["captures"] for r in v], 0)]
               for k, v in idle.items()])

    cadence = [r for r in results if r["scenario"] == "cadence"]
    if cadence:
        table("复制节奏（B3、B12）", ["轮询 s", "间隔 ms", "写入", "采到", "漏采", "延迟 p50", "p95", "最大", "CPU s", "唤醒/秒", "出错"],
              [[r["interval"], r["gap_ms"], r["writer_wrote"], r["captured"], r["missing"], r["latency_ms"].get("p50"),
                r["latency_ms"].get("p95"), r["latency_ms"].get("max"), r["cpu_s"], r["wakeups_per_s"], r["record_errors"]] for r in cadence])

    life = [r for r in results if r["scenario"] == "lifecycle"]
    if life:
        table("生命周期（B8、L46）", ["阶段", "批次", "每批次数", "内存 MB", "线程", "句柄", "窗口", "其他"],
              [[r["phase"], r["batch"], r["cycles"], r["footprint_mb"], r["threads"], r["fds"], r["windows"],
                " ".join(f"{k}={fmt(r[k])}" for k in ("refresh_timer", "loaded", "running", "open") if k in r)] for r in life])
        panel = [r["footprint_mb"] for r in life if r["phase"] == "panel"]
        if len(panel) >= 3:
            steps = [b - a for a, b in zip(panel, panel[1:])]
            print(f"\n面板开关每批内存变化（MB）：{', '.join(fmt(s) for s in steps)}；第 2 批之后平均 {fmt(statistics.mean(steps[1:]))}")

    for r in results:
        if r["scenario"] == "retention":
            print(f"\n## 淘汰与回放（B9、V15）：{r['phase']}\n")
            print("```")
            print(json.dumps({k: v for k, v in r.items() if k not in ("run", "scenario", "event")}, ensure_ascii=False, indent=1))
            print("```")

    scroll = [r for r in results if r["scenario"] == "scroll"]
    if scroll:
        table("滚动（V17）", ["轮次", "条数", "帧数", "标称 ms", "帧间隔 p50", "p95", "最大", "掉帧", "掉帧 ms/秒", "已加载", "CPU %"],
              [[r["run"], r["items"], r["frames"], r["nominal_ms"], r["frame_ms"].get("p50"), r["frame_ms"].get("p95"),
                r["frame_ms"].get("max"), r["hitches"], r["hitch_ms_per_s"], r["loaded"], r["cpu_pct_one_core"]] for r in scroll])

    store = [r for r in results if r["scenario"] == "search" and r["path"] == "store"]
    if store:
        table("搜索：直接查库（L44）", ["搜索词", "字数", "命中", "p50 ms", "p95 ms", "最大 ms"],
              [[r["term"], r["length"], r["hits"], r["query_ms"].get("p50"), r["query_ms"].get("p95"), r["query_ms"].get("max")] for r in store])
    panel = [r for r in results if r["scenario"] == "search" and r["path"] == "panel"]
    if panel:
        table("搜索：面板路径（L45）", ["搜索词", "主线程 p95 ms", "主线程最大", "出结果 p50", "出结果 p95", "主线程最长阻塞 ms"],
              [[r["term"], r["main_ms"].get("p95"), r["main_ms"].get("max"), r["total_ms"].get("p50"), r["total_ms"].get("p95"),
                r["main_stall_max_ms"]] for r in panel])

    image = [r for r in results if r["scenario"] == "image"]
    if image:
        table("大图（L09、L28），单位 ms", ["尺寸", "PNG MB", "入库", "读取", "预览主线程", "预览出图", "主线程最长阻塞", "解码", "旋转", "编码", "抠图", "内存 MB"],
              [[f"{r['width']}×{r['height']}", r["png_mb"], r["record_ms"], r["read_ms"], r["preview_main_ms"], r["preview_ready_ms"],
                r["preview_stall_max_ms"], r["decode_ms"], r["rotate_ms"], r["encode_ms"], r["lift_ms"], r["footprint_mb"]] for r in image])

    stack = [r for r in results if r["scenario"] == "stack"]
    if stack:
        table("Stack 大内容（L72），单位 ms", ["内容", "MB", "入库", "写剪贴板", "主线程最长阻塞", "入队前 MB", "入队后 MB"],
              [[r["content"], r["mb"], r["record_ms"], r["write_ms"], r["stall_max_ms"], r["footprint_before_mb"], r["footprint_queued_mb"]] for r in stack])

    sound = [r for r in results if r["scenario"] == "sound"]
    if sound:
        table("音效突发（B10）", ["音效", "阶段", "静置 s", "采到", "建了几次声音", "CPU %（单核）", "唤醒/秒", "线程", "内存 MB", "主线程最长阻塞 ms"],
              [["开" if r["sound"] else "关", r["phase"], r.get("at_s"), r.get("captured"), r.get("sounds_created"), r["cpu_pct_one_core"],
                r["wakeups_per_s"], r["threads"], r["footprint_mb"], r.get("main_stall_max_ms")] for r in sound])

    ocr = [r for r in results if r["scenario"] == "ocr" and r["phase"] == "backlog"]
    if ocr:
        table("文字识别积压（V07）", ["尺寸", "张数", "PNG MB", "入库 s", "识别 s", "每张 p50 ms", "p95", "空结果", "CPU %（单核）",
                                  "内存 MB 起始→峰值", "线程峰值", "主线程最长阻塞 ms"],
              [[f"{r['width']}×{r['height']}", r["images"], r["png_mb"], r["record_s"], r["ocr_s"], r["per_image_ms"].get("p50"),
                r["per_image_ms"].get("p95"), r["empty"], r["cpu_pct_one_core"], f"{fmt(r['footprint_start_mb'])}→{fmt(r['peak_footprint_mb'])}",
                r["peak_threads"], r["main_stall_max_ms"]] for r in ocr])
        table("识别前后的面板唤起，单位 ms", ["尺寸", "唤起主线程 前 p95", "识别中 p95", "出列表 前 p50", "前 p95", "识别中 p50", "识别中 p95", "识别中次数"],
              [[f"{r['width']}×{r['height']}", r["panel_main_before_ms"].get("p95"), r["panel_main_during_ms"].get("p95"),
                r["panel_ready_before_ms"].get("p50"), r["panel_ready_before_ms"].get("p95"), r["panel_ready_during_ms"].get("p50"),
                r["panel_ready_during_ms"].get("p95"), r["panel_ready_during_ms"].get("n")] for r in ocr])
        for r in results:
            if r["scenario"] == "ocr" and r["phase"] == "settled":
                print(f"\n识别完静置后（{r['width']}×{r['height']}）：内存 {fmt(r['footprint_mb'])} MB，线程 {r['threads']}，句柄 {r['fds']}")


if __name__ == "__main__":
    main(sys.argv[1])

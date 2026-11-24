#!/bin/zsh
# 合规检查：仓库和构建产物里不能有原版的资源、标识和整句文案。
# 用法：Tools/check-compliance.sh [构建好的 XPaste.app]
# 有问题时列出并以 1 退出。本机装有原版 Paste 时会额外做文件指纹与文案比对，没装则跳过这两项。
set -u
cd "$(dirname "$0")/.."
APP="${1:-build/DerivedData/Build/Products/Debug/XPaste.app}"
PASTE="/Applications/Paste.app"

exec python3 -I - "$APP" "$PASTE" <<'PY'
import hashlib, json, os, re, subprocess, sys, difflib, plistlib

app, paste = sys.argv[1], sys.argv[2]
failures, notes = [], []
tracked = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0")
tracked = [p for p in tracked if p and os.path.isfile(p)]
# 研究文档记录了原版的行为和标识，是否随源码公开在发布前另定；这里只报告，不算失败。
is_doc = lambda p: p.startswith("Docs/")

# 1. 参考资料目录不能入库。
if any(p.startswith("Reference/") for p in tracked):
    failures.append("Reference/ 下有文件被 git 跟踪")

# 2. 原版标识。按词边界匹配，避免把 XPaste 自己的名字当成命中。
pattern = re.compile(rb"com\.wiheads|wiheads|pasteapp\.io|Paste Team ApS", re.I)
doc_hits = []
for p in tracked:
    if p == "Tools/check-compliance.sh":  # 脚本本身要写出这些标识才能查找
        continue
    if p in ("README.md", "README.zh-CN.md"):  # README 里注明出处、推荐大家支持原版，要写原版官网
        continue
    data = open(p, "rb").read()
    if pattern.search(data):
        (doc_hits if is_doc(p) else failures).append(p if is_doc(p) else f"含原版标识：{p}")
if doc_hits:
    notes.append(f"研究文档中提到原版标识（{len(doc_hits)} 个文件）：" + "、".join(sorted(doc_hits)))

# 3. 构建产物里不能出现原版标识。
if os.path.isdir(app):
    for root, _, files in os.walk(app):
        for name in files:
            path = os.path.join(root, name)
            if not os.path.islink(path) and pattern.search(open(path, "rb").read()):
                failures.append(f"构建产物含原版标识：{os.path.relpath(path, app)}")
else:
    notes.append(f"没有找到构建产物 {app}，跳过产物检查")

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

if os.path.isdir(paste):
    # 4. 不能有与原版安装包中任何文件逐字节相同的文件（图标、音效、图片等）。
    original = {}
    for root, _, files in os.walk(paste):
        for name in files:
            path = os.path.join(root, name)
            if not os.path.islink(path) and os.path.getsize(path) > 64:
                original[sha(path)] = os.path.relpath(path, paste)
    candidates = [p for p in tracked if os.path.getsize(p) > 64]
    if os.path.isdir(app):
        candidates += [os.path.join(r, n) for r, _, fs in os.walk(app) for n in fs
                       if not os.path.islink(os.path.join(r, n)) and os.path.getsize(os.path.join(r, n)) > 64]
    for p in candidates:
        if sha(p) in original:
            failures.append(f"与原版文件相同：{p} = {original[sha(p)]}")

    # 5. 文案：与原版逐字相同的整句不行。功能性的短标签（“复制”“通用”）为保持一致允许相同。
    def strings_table(lang):
        path = f"{paste}/Contents/Resources/PastePackages_PasteLocalization.bundle/Contents/Resources/{lang}.lproj/Localizable.strings"
        if not os.path.exists(path):
            return set()
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, check=True).stdout
        return {v.strip() for v in json.loads(out).values()}
    original_text = strings_table("zh-Hans") | strings_table("en")
    def is_sentence(text):
        # 带句读、且不只是两三个词的，或者很长的，算整句；“Open at Login”“在 Finder 中显示”这类标签不算。
        cjk = len(re.findall(r"[一-鿿]", text))
        words = len(re.findall(r"[A-Za-z]+", text))
        punctuated = bool(re.search(r"[。！？；，：（]|[.!?:;,]\s|[.!?:]$", text))
        return (punctuated and (cjk >= 8 or words >= 3)) or cjk >= 16 or words >= 8
    ours = set()
    for p in tracked:
        if p.startswith("App/") and p.endswith(".swift"):
            ours |= {m.strip() for m in re.findall(r'"((?:[^"\\\n]|\\.)+)"', open(p, encoding="utf-8").read())}
        if p.endswith("Localizable.strings"):
            ours |= {m.strip() for m in re.findall(r'=\s*"((?:[^"\\]|\\.)*)";', open(p, encoding="utf-8").read())}
    for text in sorted(t for t in ours if t in original_text and is_sentence(t)):
        failures.append(f"与原版逐字相同的整句文案：{text}")
    # 只换了产品名或术语的近似句子也算照抄：统一名称后按字符相似度比较。
    def normalize(text):
        for a, b in [("XPaste", "Paste"), ("Pinboard", "钉板"), ("条目", "项目"), ("pinboard", "pinboard")]:
            text = text.replace(a, b)
        return re.sub(r"\s+", " ", text.lower())
    long_original = [normalize(t) for t in original_text if is_sentence(t)]
    for text in sorted(t for t in ours if is_sentence(t) and t not in original_text):
        mine = normalize(text)
        close = [o for o in long_original if abs(len(o) - len(mine)) <= max(8, len(mine) // 3)]
        best = max((difflib.SequenceMatcher(None, mine, o).ratio() for o in close), default=0)
        if best >= 0.8:
            failures.append(f"与原版只差个别字词的整句文案（相似度 {best:.2f}）：{text}")

    # 6. MCP 的说明和错误信息不能照原版写。按 4 个词的短语比较：自己写的同类说明几乎不会整段重合。
    def grams(text, n=4):
        words = re.findall(r"[a-z_`]+", text.lower())
        return {tuple(words[i:i + n]) for i in range(len(words) - n + 1)}
    binary = subprocess.run(["strings", "-n", "20", f"{paste}/Contents/MacOS/Paste"], capture_output=True).stdout.decode("utf-8", "ignore")
    corpus = grams(binary)
    reference = "Reference/mcp/paste-tools-list.json"
    if os.path.exists(reference):
        for tool in json.load(open(reference)):
            corpus |= grams(tool.get("description", ""))
    for path in [p for p in tracked if p.startswith("Packages/XPasteKit/Sources/MCPKit/")]:
        source = open(path, encoding="utf-8").read()
        texts = [re.sub(r"\\\n\s*", "", m) for m in re.findall(r'"""\n(.*?)"""', source, re.S)]
        texts += re.findall(r'"((?:[^"\\\n]|\\.){30,})"', source)
        for text in texts:
            # 协议规定的写法（CSP、.well-known 路径、WWW-Authenticate）必须一致，不算文案。
            if re.search(r"\.well-known|-src |resource_metadata", text):
                continue
            mine = grams(text)
            if len(mine) >= 3 and len(mine & corpus) / len(mine) > 0.25:
                failures.append(f"MCP 文案与原版短语重合过多（{len(mine & corpus) / len(mine):.0%}）：{path}：{' '.join(text.split())[:60]}…")
else:
    notes.append("本机没有原版 Paste，跳过文件指纹与文案比对")

for n in notes:
    print("说明：" + n)
if failures:
    print(f"\n发现 {len(failures)} 个问题：")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("合规检查通过")
PY

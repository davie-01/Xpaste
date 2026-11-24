#!/bin/zsh
# 文案检查：源码里的每条本地化文案在英文表里都有翻译；表里没有重复键；占位符个数一致。
# 源码里的键以简体中文书写（开发语言），所以只检查英文表。没被用到的键只提示，不算失败。
set -u
cd "$(dirname "$0")/.."

exec python3 -I - <<'PY'
import glob, re, sys

def table(path):
    text = open(path, encoding="utf-8").read()
    return re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)

failures, notes = [], []
english = table("App/Resources/en.lproj/Localizable.strings")
keys = [k for k, _ in english]
for key in sorted({k for k in keys if keys.count(k) > 1}):
    failures.append(f"英文表重复的键：{key}")
translations = dict(english)

def placeholders(text):
    # %@、%lld、%d 以及带位置的 %1$@ 都算一个占位符。
    return len(re.findall(r"%(?:\d+\$)?(?:@|lld|ld|d|f)", text))

for key, value in english:
    if placeholders(key) != placeholders(value):
        failures.append(f"占位符个数不一致：{key} → {value}")

# 源码中会被本地化的写法：String(localized:)，以及 SwiftUI 里直接写字面量的 Text、Button、Toggle、Label、Menu、Picker、TextField。
call = re.compile(r'(?:String\(localized:\s*|\b(?:Text|Button|Toggle|Label|Menu|Picker|TextField)\(\s*)"')

def literal_at(source, start):
    """从开引号后读出字符串字面量，插值 \\( … ) 里可以嵌套括号和字符串。返回按插值切开的片段。"""
    parts, current, i = [], "", start
    while i < len(source):
        ch = source[i]
        if ch == "\\" and source[i + 1] == "(":
            depth, j, in_string = 1, i + 2, False
            while depth:
                c = source[j]
                if in_string:
                    if c == "\\": j += 1
                    elif c == '"': in_string = False
                elif c == '"': in_string = True
                elif c == "(": depth += 1
                elif c == ")": depth -= 1
                j += 1
            parts.append(current); current, i = "", j
            continue
        if ch == "\\":
            current += source[i:i + 2]; i += 2; continue
        if ch in '"\n':
            break
        current += ch; i += 1
    parts.append(current)
    return parts

from itertools import product
used = set()
for path in glob.glob("App/**/*.swift", recursive=True):
    if "SelfTest" in path:
        continue
    source = open(path, encoding="utf-8").read()
    for match in call.finditer(source):
        parts = literal_at(source, match.end())
        literal = "\\(…)".join(parts)
        # 汉字之外，单独的中文标点（“，”“、”）也要翻译。
        if not re.search(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]", literal):
            continue
        # 插值的类型在源码里看不出来，每个占位符 %@ 和 %lld 都试。
        hit = None
        for combo in product(["%@", "%lld"], repeat=len(parts) - 1):
            candidate = parts[0] + "".join(c + p for c, p in zip(combo, parts[1:]))
            if candidate in translations:
                hit = candidate
                break
        if hit is None:
            failures.append(f"英文表缺少：{literal}  （{path}）")
        else:
            used.add(hit)

unused = [k for k in keys if k not in used and re.search(r"[一-鿿]", k)]
if unused:
    notes.append(f"英文表里有 {len(unused)} 个键在源码中没找到（可能是动态拼出的文案，或已不再使用）：")
    notes += ["    " + k for k in unused]

for n in notes:
    print(n)
if failures:
    print(f"\n发现 {len(failures)} 个问题：")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print(f"文案检查通过：源码中 {len(used)} 条文案都有英文翻译")
PY

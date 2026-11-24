#!/bin/zsh
# 把本地 main 的公开部分同步到 public 分支，需要时推到 GitHub。
#
#   Tools/publish-public.sh "提交说明"          # 只在本地 public 分支上生成一个提交，列出改了哪些文件
#   Tools/publish-public.sh "提交说明" --push   # 同上，再把 public 推到远端仓库的 main
#
# 公开仓库的历史和本地 main 分开：开发过程中的研究记录（Docs/：原版的界面测量、二进制里读出的文案等）
# 和测量原版用的小工具不公开，所以不能直接推 main。这里用一个临时索引从 main 的最新提交里去掉这些路径，
# 写成 public 分支上的一个新提交；工作区和 main 都不动。
set -euo pipefail
cd "$(dirname "$0")/.."

MESSAGE=${1:?用法：Tools/publish-public.sh "提交说明" [--push]}
PUSH=${2:-}
REMOTE=${PUBLIC_REMOTE:-origin}

# 不公开的路径。
PRIVATE_PATHS=(
  Docs
  Tools/axdump.swift
  Tools/click.swift
  Tools/stackprobe.sh
  Tools/stackprobe.swift
)

INDEX=$(mktemp -t xpaste-public-index)
trap 'rm -f "$INDEX"' EXIT
export GIT_INDEX_FILE=$INDEX
git read-tree main
git rm -r --cached --quiet --ignore-unmatch -- "${PRIVATE_PATHS[@]}"
TREE=$(git write-tree)
unset GIT_INDEX_FILE

if git rev-parse --verify --quiet refs/heads/public >/dev/null; then
  PARENT=$(git rev-parse public)
  if [[ $(git rev-parse "public^{tree}") == "$TREE" ]]; then
    echo "公开部分和 public 分支一样，没有要同步的。"
  else
    COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -m "$MESSAGE")
    git update-ref refs/heads/public "$COMMIT" "$PARENT"
    echo "public 分支新提交 $(git rev-parse --short public)，改动："
    git diff --stat "$PARENT" public | tail -20
  fi
else
  COMMIT=$(git commit-tree "$TREE" -m "$MESSAGE")
  git update-ref refs/heads/public "$COMMIT"
  echo "public 分支首次提交 $(git rev-parse --short public)，共 $(git ls-tree -r --name-only public | wc -l | tr -d ' ') 个文件。"
fi

# 公开树里不能有研究文档。
if git ls-tree -r --name-only public | grep -E '^(Docs/|Reference/)' >/dev/null; then
  echo "public 分支里还有 Docs/ 或 Reference/ 下的文件，停止。" >&2
  exit 1
fi

if [[ $PUSH == --push ]]; then
  git push "$REMOTE" public:main
fi

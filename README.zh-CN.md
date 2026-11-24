# XPaste

[English](README.md) | 简体中文

一个 macOS 剪贴板历史管理工具，用 Swift 从零写起，是我个人的学习研究项目。

XPaste 记下你复制过的内容（文本、富文本、图片、链接、颜色、文件），放在屏幕底部的面板里，可以随时搜索、预览、编辑，再粘贴回去。

## 为什么做它

这是一个学习项目。我每天都在用 [**Paste**](https://pasteapp.io/)，非常喜欢它，想弄明白这样一个应用是怎么做出来的：剪贴板采集、又快又能搜的历史、精致的 AppKit 面板、按顺序粘贴、隐私控制、本机 MCP 服务……

所以 XPaste 的思路和用法都尽量贴近 Paste，但它是独立重写的：不含 Paste 的任何代码、图片、音效和文案，和 Paste 的开发者没有任何关系，也没有得到他们的认可。

**如果你是想找一个剪贴板工具来日常使用，请购买 Paste，支持原版的开发者。** 它更好用，能在 Mac、iPhone、iPad 之间同步，也在持续更新。XPaste 更适合想读代码、拿来学习的人。

## 功能

- **剪贴板历史**：每次复制都存在本机，包括纯文本和富文本、图片、链接（带网页标题和配图）、颜色、文件。密码管理器标记为机密或临时的内容不记录，也可以整个忽略某些应用。
- **屏幕底部的面板**：按 **⇧⌘V** 打开。卡片显示内容、来源应用和复制时间。回车或双击粘贴，⇧回车以纯文本粘贴，⌘1–⌘9 直接粘贴前 9 条。
- **搜索和筛选**：搜索文字、标题，以及图片里识别出的文字（本机识别）；可以按类型、来源应用、Pinboard 筛选。
- **Pinboard**：常用的内容放进带名字和颜色的 Pinboard，不会过期。
- **预览和编辑**：按空格预览文本、图片、网页和文件；可以编辑文本、链接、颜色和图片（旋转、移除背景）。
- **多选**：一次粘贴或拖出多条，文本逐行拼在一起。
- **Paste Stack**：按 **⇧⌘C**，把要用的东西依次复制进来，再按 ⌘V 一次粘一条、按顺序粘回去。也可以用面板里选中的条目建一个 Stack；拖动行调整顺序，双击某一行先粘它，⌃⌥⌘V 一次粘出全部文本，删掉的可以撤销。
- **给 AI 工具用的 MCP 服务**：可选，默认关闭。打开后只监听本机 `127.0.0.1`，每个新连接都要在 XPaste 里确认。Claude Code、Codex、Cursor 等 MCP 客户端可以搜索历史、读取条目、管理 Pinboard、往 Paste Stack 里加东西。
- **其他**：面板高度可调可锁定、保留期限、暂停记录、提示音、屏幕共享时隐藏窗口（对遵守这个标记的工具有效）、登录时打开、首次启动引导、简体中文和英文界面。

## 系统要求

- macOS 27 或更新版本
- Apple Silicon（只有 arm64 版本，不提供 Intel 或通用版本）

## 安装

目前还没有发布版本。以后会放在 [Releases](https://github.com/davie-01/Xpaste/releases) 页面，是一个 zip 包加一个 SHA-256 校验文件。

安装包是 ad-hoc 签名，没有经过苹果公证，下载后会被系统隔离。解压并把 XPaste 放进 `/Applications` 后：

```sh
shasum -a 256 -c XPaste-<版本>-arm64.zip.sha256   # 校验下载的文件
xattr -dr com.apple.quarantine /Applications/XPaste.app
open /Applications/XPaste.app
```

## 从源码构建

需要 Xcode 27 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
git clone https://github.com/davie-01/Xpaste.git
cd Xpaste
brew install xcodegen

# 打一个 Release 包（ad-hoc 签名），放在 dist/ 下
Tools/package.sh
```

日常开发：

```sh
xcodegen generate
xcodebuild -project XPaste.xcodeproj -scheme XPaste -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/XPaste.app
```

`project.yml` 里用的是作者的开发团队（`DEVELOPMENT_TEAM`）签名，请换成你自己的团队 ID，或者用 `Tools/package.sh`，它用 ad-hoc 签名。Debug 版的快捷键是 ⌃⇧⌘V 和 ⌃⇧⌘C，数据也单独存放，可以和发布版同时运行。

测试和检查：

```sh
swift test --package-path Packages/XPasteKit   # 单元测试
Tools/check-strings.sh                         # 每条界面文案都有英文翻译
Tools/check-compliance.sh                      # 没有从 Paste 拷来的资源、标识和文案
XPASTE_SELFTEST=1 build/DerivedData/Build/Products/Debug/XPaste.app/Contents/MacOS/XPaste   # 应用内自检
```

## 权限和隐私

- **设备控制和数据访问**（旧版 macOS 叫“辅助功能”）：直接粘贴到正在用的应用、以及 Paste Stack 需要它。没有授权时，XPaste 只把内容放进剪贴板，由你自己按 ⌘V。这个授权和代码签名绑定，每次换了 ad-hoc 签名的新版本都要重新允许。
- **文件和文件夹**：第一次粘贴从桌面、文稿、下载、移动硬盘或网络磁盘复制来的文件时，系统会询问。
- **网络**：只用来获取链接的标题和配图、显示网页预览，两项都可以在“设置 › 隐私”里关掉；本机和内网地址一律不加载。
- **数据**：都留在你的 Mac 上，在 `~/Library/Application Support/XPaste`。没有同步、账号、统计或遥测。
- **屏幕共享**：“在屏幕共享期间显示”关掉后，XPaste 的窗口会标记为不可共享。很多现在的录屏和共享工具不理会这个标记，所以它不能防截图或防录屏。

## 已知限制

- **Stack 粘得太快**：每按一次 ⌘V，XPaste 就把下一项写进剪贴板。如果目标应用读剪贴板比较慢，而你按得比这还快，两次按键可能粘出同一项。遇到时请放慢一点。
- **来源应用**：复制的应用没有自报身份时，来源记为复制那一刻的前台应用，所以后台工具写进剪贴板的内容会记在前台应用名下。
- **删掉又回来**：某个应用在你删掉它的条目后又重新写剪贴板，这条会作为一次新的复制回来。
- 这个项目背后的开发记录和研究资料（对 Paste 的测量和比对）不在这个仓库里，所以有些代码注释提到的文档在这里找不到。

## 项目状态

个人学习项目，只在我自己的 Mac 上构建和测试过。欢迎提 Issue 和 PR，但不保证功能和回复时间。

## 许可

MIT，见 [LICENSE](LICENSE)。用到的第三方组件见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 致谢

- 灵感来自 [**Paste**](https://pasteapp.io/)，请支持原版。
- 数据库用的是 [GRDB.swift](https://github.com/groue/GRDB.swift)。
- 界面用 AppKit 和 SwiftUI，另外用到苹果的 Vision（文字识别、移除背景）、WebKit（网页预览）和 Network（MCP 服务）。

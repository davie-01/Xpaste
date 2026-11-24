import AppKit
import SwiftUI

/// “XPaste 帮助”窗口：常用功能和用法的简短说明。快捷键按用户当前的设置显示。
@MainActor
final class HelpWindowController: NSWindowController {
    init(preferences: AppPreferences = .shared) {
        let window = StandardWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        WindowSharing.apply(to: window, preferences: preferences)
        window.title = String(localized: "XPaste 帮助")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 400)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: HelpView(preferences: preferences))
        window.center()
        window.setFrameAutosaveName("XPasteHelp")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        // 快捷键可能刚在设置里改过，每次打开都按当前设置重画。
        if let window, let preferences = (window.contentView as? NSHostingView<HelpView>)?.rootView.preferences {
            window.contentView = NSHostingView(rootView: HelpView(preferences: preferences))
        }
        AppActivation.bringToFront()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    let preferences: AppPreferences

    private var keys: KeyboardSettings { preferences.keyboardSettings }
    private func shortcut(_ value: RecordedShortcut?) -> String { value?.display ?? String(localized: "（未设置）") }
    private func modifier(_ value: ShortcutModifier) -> String { String(value.title.prefix(1)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("XPaste 帮助").font(.title2.bold())
                        Text("XPaste 记下你复制过的内容，需要时随时找回来再粘贴。").foregroundStyle(.secondary)
                    }
                }
                section("打开与关闭", symbol: "rectangle.bottomthird.inset.filled", [
                    String(localized: "按 \(shortcut(keys.activation)) 或点菜单栏图标，面板从屏幕底部出现。"),
                    String(localized: "再按一次快捷键、按 Esc 或点面板外面就会收起。"),
                    String(localized: "右键点菜单栏图标可以打开菜单：暂停记录、设置、退出等。"),
                    String(localized: "拖动面板上缘调整高度，双击上缘恢复默认高度；右键上缘可以锁定高度。"),
                ])
                section("选择与粘贴", symbol: "doc.on.clipboard", [
                    String(localized: "单击选中一条，双击或按回车把它粘贴到正在使用的应用。"),
                    String(localized: "按 \(modifier(keys.quickPaste)) 加数字 1–9，直接粘贴面板里的前 9 条。"),
                    String(localized: "粘贴时按住 \(modifier(keys.plainText))，去掉字体、颜色等格式，以纯文本粘贴。"),
                    String(localized: "← → 移动选中，按住 ⇧ 可以多选，⌘A 全选；⌘C 只复制到剪贴板、不粘贴。"),
                    String(localized: "卡片也可以直接拖到其他应用里。"),
                ])
                section("查找", symbol: "magnifyingglass", [
                    String(localized: "面板打开后直接打字就会开始搜索，图片里的文字也能搜到。"),
                    String(localized: "用搜索框旁的筛选，按内容类型、来源应用或 Pinboard 缩小范围。"),
                ])
                section("预览与编辑", symbol: "eye", [
                    String(localized: "按空格预览选中的内容，再按一次或按 Esc 关闭。"),
                    String(localized: "⌘E 编辑文本或图片，⌘R 给条目起个名字，⌘N 新建一条文本。"),
                ])
                section("Pinboard", symbol: "pin", [
                    String(localized: "常用的内容可以固定到 Pinboard 里，不会随保留期限被清掉。"),
                    String(localized: "把卡片拖到顶部的页签上就能固定；⇧⌘N 新建 Pinboard。"),
                    String(localized: "按 \(shortcut(keys.previousPinboard)) / \(shortcut(keys.nextPinboard)) 在页签之间切换。"),
                ])
                section("Paste Stack", symbol: "square.stack.3d.up", [
                    String(localized: "按 \(shortcut(keys.stack)) 打开 Paste Stack，之后复制的内容会依次排进队列；在面板里选中条目再按它，或右键选“创建 Stack”，就用选中的条目建一个。"),
                    String(localized: "⌘V 每次粘出最上面一条。拖动行可以调整顺序，双击某一行先粘它，⌃⌥⌘V 一次粘出全部文本。"),
                    String(localized: "点 × 移除一行；移除、提前粘出或拖到别的应用之后，可以点标题栏的撤销放回原处。"),
                ])
                section("删除、撤销与暂停", symbol: "arrow.uturn.backward", [
                    String(localized: "按 Delete 删除选中的条目，⌘Z 可以撤销刚才的删除。"),
                    String(localized: "⌘T 暂停记录，再按一次恢复；也可以在菜单里选择暂停一段时间。"),
                ])
                section("隐私与权限", symbol: "hand.raised", [
                    String(localized: "密码管理器等标记为保密的内容不会被记录；在“设置 › 隐私”里还可以忽略指定的应用。"),
                    String(localized: "要把内容直接粘贴到其他应用，需要在系统设置的“设备控制和数据访问”中允许 XPaste；不允许时内容会放进剪贴板，由你按 ⌘V 粘贴。"),
                    String(localized: "所有历史只保存在这台 Mac 上。"),
                ])
                Text("快捷键都可以在“设置 › 键盘快捷键”里修改。").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: LocalizedStringKey, symbol: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.leading, 4)
        }
    }
}

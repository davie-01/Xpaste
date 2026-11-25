import AppKit
import SwiftUI
import ClipboardKit

/// 设置里的“权限”页（用户要求，2026-11-25）：设备控制和数据访问、完全磁盘访问，各自的用途、当前是否已允许和设置入口。
/// 状态来自 `TrustStatus`，设置窗口开着时每秒刷新，在系统设置里切换后这里马上跟着变。
struct PermissionsSettingsView: View {
    private var status: TrustStatus { TrustStatus.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            permission(
                title: String(localized: "设备控制和数据访问"),
                detail: String(localized: "允许后，选中的内容会直接粘贴到正在使用的应用。不允许也能使用：内容会放进剪贴板，由你按 ⌘V 粘贴。"),
                granted: status.isTrusted, optional: false
            ) {
                if !status.isTrusted {
                    Button(String(localized: "允许访问")) { PastePerformer.requestTrust() }
                }
                Button(String(localized: "打开系统设置")) { SystemSettings.openPrivacy("Privacy_Accessibility") }
            }
            permission(
                title: String(localized: "完全磁盘访问（可选）"),
                detail: String(localized: "粘贴“文稿”“桌面”“下载”等文件夹里的文件时，系统会逐个文件夹询问。授予完全磁盘访问后不再询问。XPaste 只读取你复制过的文件，不会扫描磁盘。"),
                granted: status.hasFullDiskAccess, optional: true
            ) {
                Button(String(localized: "打开系统设置")) { SystemSettings.openPrivacy("Privacy_AllFiles") }
            }
        }
    }

    private func permission(title: String, detail: String, granted: Bool, optional: Bool,
                            @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold)
                Spacer()
                if granted {
                    Label(String(localized: "已允许"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    // 必需的权限没给用橙色提醒；可选的只是灰色说明。
                    Label(String(localized: "未允许"), systemImage: optional ? "circle" : "exclamationmark.circle.fill")
                        .foregroundStyle(optional ? Color.secondary : Color.orange)
                }
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions() }.padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

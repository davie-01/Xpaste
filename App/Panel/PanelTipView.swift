import AppKit

/// 每个提示独占一张与历史卡片同尺寸的卡片，不参与历史选择和快捷粘贴编号。
/// 提示卡片装在面板长期持有的提示容器里，容器放在滚动内容中、排在第一张历史卡片之前，和卡片一起横向滚动（原版如此）。
/// 版式照原版的提示卡片：左上角图标，下面是标题和说明，左下角胶囊按钮，右上角关闭；底色是半透明的，透出面板的玻璃。
@MainActor
final class PanelTipView: NSView {
    var onEnable: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let icon = NSImageView()
    private let enable: NSButton
    private let enableBackground = NSView()

    init(tip: PanelTip) {
        enable = NSButton(title: String(localized: "启用"), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PanelMetrics.cardCornerRadius
        layer?.cornerCurve = .continuous
        let name = tip == .directPaste ? String(localized: "启用直接粘贴") : String(localized: "登录时打开")

        icon.image = NSImage(systemSymbolName: tip == .directPaste ? "cursorarrow.rays" : "power", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)

        // 标题是普通标签，说明可换行但显式关掉文字选择（原版如此）：点在提示上不会进入选字，辅助功能仍按静态文字朗读。
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(wrappingLabelWithString: tip == .directPaste
            ? String(localized: "授权后可直接粘贴到其他应用。") : String(localized: "登录后自动准备好剪贴板历史。"))
        detail.isSelectable = false
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        enable.target = self
        enable.action = #selector(enableClicked)
        enable.isBordered = false
        enable.font = .systemFont(ofSize: 13, weight: .medium)
        enable.contentTintColor = .labelColor
        // 两张提示的按钮都叫“启用”，单独听分不清，辅助功能的名称说清启用什么（直接粘贴那张的标题本身就是）。
        enable.setAccessibilityLabel(tip == .directPaste ? name : String(localized: "启用：\(name)"))
        enableBackground.wantsLayer = true
        enableBackground.layer?.cornerRadius = 14

        // × 只关掉这一次面板里的提示；下次打开面板时条件还成立（例如仍未授权）就再显示。
        let closeLabel = String(localized: "关闭此提示")
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel)!, target: self, action: #selector(dismissClicked))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = closeLabel
        for view in [icon, title, detail, enableBackground, enable, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: enableBackground.topAnchor, constant: -8),
            enableBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            enableBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            enableBackground.heightAnchor.constraint(equalToConstant: 28),
            enable.leadingAnchor.constraint(equalTo: enableBackground.leadingAnchor, constant: 12),
            enable.trailingAnchor.constraint(equalTo: enableBackground.trailingAnchor, constant: -12),
            enable.centerYAnchor.constraint(equalTo: enableBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    /// 底色和描边在每次重画时按当前外观和显示选项设置，面板每次打开都会让它重画。
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 增强对比度时底色加深、加描边；不然半透明的底色和面板几乎一样，看不出边界。
        let contrast = DisplayOptions.increaseContrast
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(contrast ? 0.16 : 0.08)
                                       : NSColor.black.withAlphaComponent(contrast ? 0.10 : 0.05)).cgColor
        layer?.borderWidth = contrast ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.cgColor
        enableBackground.layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)).cgColor
    }
    /// 点在提示卡片的空白处不交给后面的集合视图：提示不参与历史卡片的选中、框选和拖动，只响应自己的按钮。
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    @objc private func enableClicked() { onEnable?() }
    @objc private func dismissClicked() { onDismiss?() }
}

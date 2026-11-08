import AppKit

/// 鼠标停在卡片上时弹出的放大预览。
///
/// 调用时机：AppDelegate.tick() 每帧检查光标，在同一个卡片上停够 hoverDelay 之后调 show，
/// 离开后调 hide。
///
/// 显示什么：
/// - 文字卡 / 链接卡 → 直接显示原文（旁边那个 .txt），所以长内容也能看全，不只是看放大的图
/// - 图片卡 → 显示放大后的原图
///
/// 这个窗不接收鼠标（ignoresMouseEvents），所以鼠标划过去不会挡住下面的东西，
/// 也不会打断「指针在卡片上」的判断；是否该收起由调用方用 contains(_:) 判断。
@MainActor
final class HoverPreview {

    static let shared = HoverPreview()

    private var panel: NSPanel?
    private var shownURL: URL?

    /// 预览窗最大尺寸（点）
    private static let maxWidth: CGFloat = 420
    private static let maxHeight: CGFloat = 520
    /// 内容四周留白
    private static let padding: CGFloat = 18
    /// 卡片与预览之间的空隙
    private static let gap: CGFloat = 10

    // MARK: - 对外

    /// 预览是不是正显示着。
    /// 调用时机：AppDelegate 决定要不要走「宽限期后收起」那段逻辑。
    var isShowing: Bool { shownURL != nil }

    /// 显示预览。同一个文件已经显示时只跟着卡片挪位置，不重建视图（每帧都会调）。
    func show(url: URL, below card: CGRect) {
        if shownURL == url, let panel, panel.isVisible {
            panel.setFrameOrigin(origin(for: panel.frame.size, below: card))
            return
        }

        let made = makeContent(for: url)
        let panel = self.panel ?? makePanel()
        panel.contentView = made.view
        panel.setFrame(NSRect(origin: origin(for: made.size, below: card), size: made.size),
                       display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        shownURL = url
    }

    /// 收起预览。
    func hide() {
        guard shownURL != nil else { return }
        panel?.orderOut(nil)
        shownURL = nil
    }

    /// 这个屏幕坐标点是不是落在预览窗里。
    /// 调用时机：调用方判断「鼠标已经离开卡片」时，再看一眼是不是移到了预览上，
    /// 是的话就别收，否则预览会一闪就没，根本看不成。
    func contains(_ point: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        // 留 8 点宽容距离，鼠标贴着边缘移动不算离开
        return panel.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    // MARK: - 窗口

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // 不接收鼠标：不抢焦点、不挡下面的窗口、不干扰卡片的悬停判断
        panel.ignoresMouseEvents = true
        return panel
    }

    /// 算预览窗该放哪：默认贴在卡片下方，下方放不开就翻到上方，左右不出屏幕。
    private func origin(for size: NSSize, below card: CGRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(card) }
            ?? LinePanel.screenUnderPointer() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = card.midX - size.width / 2
        var y = card.minY - Self.gap - size.height
        if y < visible.minY + 8 {
            // 屏幕底部放不下，改放卡片上方
            y = card.maxY + Self.gap
        }
        if y + size.height > visible.maxY - 8 {
            y = max(visible.minY + 8, visible.maxY - size.height - 8)
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: y)
    }

    // MARK: - 内容

    private func makeContent(for url: URL) -> (view: NSView, size: NSSize) {
        if let text = originalText(of: url) {
            return makeText(text)
        }
        return makeImage(url)
    }

    /// 文字卡 / 链接卡旁边那个 .txt 里的原文。
    /// 文件名前缀要和桥写卡片时保持一致，否则会把普通截图旁边的同名 txt 当成原文。
    private func originalText(of card: URL) -> String? {
        let name = card.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("文字_") || name.hasPrefix("链接_") else { return nil }
        let sidecar = card.deletingPathExtension().appendingPathExtension("txt")
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// 文字预览：按内容高度撑开，超过上限就截断（上限内基本能看全，实在长就用右键 Hold）。
    private func makeText(_ text: String) -> (view: NSView, size: NSSize) {
        let width = Self.maxWidth - Self.padding * 2
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        let maxTextHeight = Self.maxHeight - Self.padding * 2
        var display = text
        var height = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).height

        // 超长就在字符层面二分截断，末尾补省略号
        if height > maxTextHeight {
            var low = 0
            var high = text.count
            var best = ""
            for _ in 0..<18 {
                let mid = (low + high + 1) / 2
                let candidate = String(text.prefix(mid)) + "…"
                let h = (candidate as NSString).boundingRect(
                    with: NSSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attrs
                ).height
                if h <= maxTextHeight {
                    best = candidate
                    low = mid
                } else {
                    high = mid - 1
                }
                if low >= high { break }
            }
            display = best.isEmpty ? "…" : best
            height = (display as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            ).height
        }

        height = ceil(height) + 4
        let box = PreviewBox()
        let field = NSTextField(wrappingLabelWithString: display)
        field.font = font
        field.textColor = .labelColor
        field.isSelectable = false
        field.isEditable = false
        field.drawsBackground = false
        field.frame = NSRect(x: Self.padding, y: Self.padding, width: width, height: height)
        // 文本从上往下排：AppKit 原点在左下，所以高度要按内容反着摆
        field.frame.origin.y = Self.padding
        box.addSubview(field)
        box.frame = NSRect(x: 0, y: 0, width: Self.maxWidth, height: height + Self.padding * 2)
        return (box, box.frame.size)
    }

    /// 图片预览：按比例放大，最多放到 3 倍（避免小图糊成大色块）。
    private func makeImage(_ url: URL) -> (view: NSView, size: NSSize) {
        let box = PreviewBox()
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            // 读不出图就退回一个很小占位，避免弹一个空白框
            box.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
            return (box, box.frame.size)
        }

        let maxW = Self.maxWidth - Self.padding * 2
        let maxH = Self.maxHeight - Self.padding * 2
        let scale = min(maxW / image.size.width, maxH / image.size.height, 3)
        let shown = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = NSRect(x: Self.padding, y: Self.padding,
                            width: shown.width, height: shown.height)
        box.addSubview(view)
        box.frame = NSRect(x: 0, y: 0,
                           width: shown.width + Self.padding * 2,
                           height: shown.height + Self.padding * 2)
        return (box, box.frame.size)
    }
}

/// 预览窗的底：圆角 + 细边，跟系统的浮层一个观感。
final class PreviewBox: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

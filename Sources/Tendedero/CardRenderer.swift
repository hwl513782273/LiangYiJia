import AppKit

/// 把「文字」和「链接」画成一张卡片 PNG。
/// 调用时机：ClipboardWatcher 识别出文字 / 链接之后，在后台队列调用这里，
/// 拿到 PNG 数据再交给 ClipboardWatcher 自己写进截图文件夹挂上线。
///
/// 为什么是「画成图片」：晾衣绳线上的一条就是一个图片文件，
/// 画成图片才能直接复用它原有的拖拽、复制、QuickLook、Markup 全部能力。
///
/// 本文件从「万能挂载」工程原样搬入，只是把注释里的投递方从 BridgeWriter 换成 ClipboardWatcher。
enum CardRenderer {

    // MARK: - 版式常量（单位都是逻辑点，输出时统一乘 scale）

    /// 卡片宽度。
    /// 这个数值不是随便定的：挂上线时会被压进 150×104 点的框里
    /// （LineView.Layout.cardWidth / photoMaxHeight），所以卡片越宽，
    /// 缩得越狠、字越小。220 点宽是实测下来「缩完之后还能读」的上限。
    private static let cardWidth: CGFloat = 220
    /// 内边距
    private static let padding: CGFloat = 16
    /// 正文最高多少就折叠。超过部分截断并标注。
    /// 不能给太大：卡片一高，缩放就由高度主导，字会跟着变小。
    private static let maxBodyHeight: CGFloat = 116
    /// 2 倍输出，Retina 屏上不糊（也保证右键 Hold 放大看时依旧清晰）
    private static let scale: CGFloat = 2
    private static let cornerRadius: CGFloat = 10

    // MARK: - 配色

    /// 一套配色。深浅两种外观各一套，跟随系统
    private struct Palette {
        let background: NSColor
        let primary: NSColor
        let secondary: NSColor
        let accent: NSColor
        /// 浅色底需要一圈描边才不至于和白色背景糊在一起；深色底用 nil
        let border: NSColor?
    }

    /// 根据深浅色挑配色。
    /// 调用时机：每次生成卡片前，由 textCard / linkCard 传入。
    /// 注意传的是 Bool 而不是 NSAppearance：外观必须在主线程取好，
    /// 画卡片发生在后台队列，AppKit 的对象不能跨线程用。
    private static func palette(isDark: Bool) -> Palette {
        if isDark {
            return Palette(
                background: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1), // #1E1E20
                primary: NSColor(srgbRed: 0.933, green: 0.933, blue: 0.941, alpha: 1),    // #EEEEF0
                secondary: NSColor(srgbRed: 0.545, green: 0.545, blue: 0.565, alpha: 1),  // #8B8B90
                accent: NSColor(srgbRed: 0.396, green: 0.706, blue: 1.0, alpha: 1),       // #65B4FF
                border: NSColor(white: 1.0, alpha: 0.08)
            )
        }
        return Palette(
            background: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
            primary: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1),     // #1C1C1E
            secondary: NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1),  // #8E8E93
            accent: NSColor(srgbRed: 0.039, green: 0.404, blue: 0.761, alpha: 1),     // #0A67C2
            border: NSColor(srgbRed: 0.890, green: 0.890, blue: 0.906, alpha: 1)      // #E3E3E7
        )
    }

    // MARK: - 对外接口

    /// 生成「文字卡」。
    /// - Parameters:
    ///   - text: 原始文本（内部会压缩多余空行）
    ///   - source: 来源 App 名称，显示在卡片顶部
    ///   - date: 复制时间
    ///   - isDark: 是否深色外观（主线程取好再传进来）
    /// - Returns: PNG 数据；失败返回 nil
    static func textCard(text: String, source: String, date: Date, isDark: Bool) -> Data? {
        let pal = palette(isDark: isDark)
        let body = tidy(text)

        // 正文样式：行距 4 点，中文段落才不会挤在一起
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: pal.primary,
            .paragraphStyle: paragraph,
        ]

        let textWidth = cardWidth - padding * 2
        // 超长文本先截断出「能塞进 maxBodyHeight」的那一段
        let fitted = fit(body, attrs: bodyAttrs, width: textWidth, maxHeight: maxBodyHeight)
        // 加 6 点余量：boundingRect 不含最后一行下方的行距和字母下伸部分，
        // 不留这点富余，最后一行会被裁掉半截
        let bodyHeight = max(ceil(fitted.height) + 6, 20)

        // 顶部一行「来源 · 时间」，底部一行字数
        let headerHeight: CGFloat = 14
        let footerHeight: CGFloat = 13
        let gapHeader: CGFloat = 8
        let gapFooter: CGFloat = 8

        let totalHeight = padding + headerHeight + gapHeader + bodyHeight + gapFooter + footerHeight + padding

        return render(size: NSSize(width: cardWidth, height: totalHeight)) {
            drawBackground(size: NSSize(width: cardWidth, height: totalHeight), palette: pal)

            // 顶部：来源 App · 时间
            let headerAttrs = smallAttrs(pal, size: 10.5)
            draw("\(source) · \(timeString(date))", x: padding, top: padding,
                 height: headerHeight, width: textWidth, attrs: headerAttrs, singleLine: true)

            // 正文
            let bodyTop = padding + headerHeight + gapHeader
            draw(fitted.text, x: padding, top: bodyTop,
                 height: bodyHeight, width: textWidth, attrs: bodyAttrs, singleLine: false)

            // 底部：字数；被截断时补一句提示
            let note = fitted.truncated
                ? "\(grouped(fitted.total)) 字符 · 已截断"
                : "\(grouped(fitted.total)) 字符"
            let footerAttrs = smallAttrs(pal, size: 10.5)
            let footerTop = bodyTop + bodyHeight + gapFooter
            draw(note, x: padding, top: footerTop, height: footerHeight,
                 width: textWidth, attrs: footerAttrs, singleLine: true)
        }
    }

    /// 生成「链接卡」：域名、网页标题、完整地址。
    /// 调用时机：ClipboardWatcher 判定整段内容是一个网址时。
    /// - Parameter title: 抓到的网页标题；nil 时只显示域名和地址
    static func linkCard(url: URL, title: String?, source: String, date: Date,
                         isDark: Bool) -> Data? {
        let pal = palette(isDark: isDark)
        let textWidth = cardWidth - padding * 2
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString

        let headerHeight: CGFloat = 14
        let hostHeight: CGFloat = 17
        let urlHeight: CGFloat = 14

        // 标题最多两行，超出省略
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineSpacing = 2
        titleParagraph.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: pal.primary,
            .paragraphStyle: titleParagraph,
        ]

        var titleHeight: CGFloat = 0
        var cleanTitle: String? = nil
        if let title, !title.isEmpty {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                cleanTitle = t
                // 同上，量出来的高度要留余量，否则第二行会被裁
                titleHeight = min(ceil(measure(t, attrs: titleAttrs, width: textWidth).height) + 5, 44)
            }
        }

        let totalHeight = padding + headerHeight + 8 + hostHeight
            + (cleanTitle == nil ? 0 : 8) + titleHeight + 8 + urlHeight + padding

        return render(size: NSSize(width: cardWidth, height: totalHeight)) {
            drawBackground(size: NSSize(width: cardWidth, height: totalHeight), palette: pal)

            var y = padding
            draw("\(source) · \(timeString(date))", x: padding, top: y, height: headerHeight,
                 width: textWidth, attrs: smallAttrs(pal, size: 10.5), singleLine: true)
            y += headerHeight + 8

            // 域名行：用强调色，一眼看出是哪个站
            let hostAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: pal.accent,
            ]
            draw(host, x: padding, top: y, height: hostHeight,
                 width: textWidth, attrs: hostAttrs, singleLine: true)
            y += hostHeight

            if let cleanTitle {
                y += 8
                draw(cleanTitle, x: padding, top: y, height: titleHeight,
                     width: textWidth, attrs: titleAttrs, singleLine: false)
                y += titleHeight
            }

            y += 8
            let urlAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: pal.secondary,
            ]
            draw(url.absoluteString, x: padding, top: y, height: urlHeight,
                 width: textWidth, attrs: urlAttrs, singleLine: true)
        }
    }

    // MARK: - 内部工具

    /// 统一的绘制入口：建位图、切图形上下文、回调里画、最后编码成 PNG。
    /// 调用时机：textCard / linkCard 各自算好尺寸后调用。
    private static func render(size: NSSize, body: () -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // size 设成逻辑尺寸，这样下面所有绘制都按「点」算，像素自动按 2 倍
        rep.size = size

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.setShouldAntialias(true)
        ctx.cgContext.interpolationQuality = .high
        body()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// 画圆角底 + 描边。
    /// 调用时机：render 内部最先调用，保证内容压在上面。
    private static func drawBackground(size: NSSize, palette: Palette) {
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        palette.background.setFill()
        path.fill()
        if let border = palette.border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// 在「距卡片顶部 top」的位置画一段文字。
    /// AppKit 的绘图坐标原点在左下，这里做一次换算，调用方只管写「离顶部多远」。
    /// 调用时机：卡片里所有文字绘制都走这里。
    private static func draw(_ text: String, x: CGFloat, top: CGFloat, height: CGFloat,
                            width: CGFloat, attrs: [NSAttributedString.Key: Any],
                            singleLine: Bool) {
        // 需要一个总高度才能换算，这里用「top + height」相对当前上下文高度反推
        let contextHeight = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath.height
            ?? (top + height)
        let rect = NSRect(x: x, y: contextHeight - top - height, width: width, height: height)
        let options: NSString.DrawingOptions = singleLine
            ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            : [.usesLineFragmentOrigin, .usesFontLeading]
        (text as NSString).draw(with: rect, options: options, attributes: attrs, context: nil)
    }

    /// 量一段文字占多高。
    /// 调用时机：算卡片总高度、以及判断超长是否需要截断。
    private static func measure(_ text: String, attrs: [NSAttributedString.Key: Any],
                                width: CGFloat) -> NSSize {
        (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
    }

    /// 判断文本是否超长，超长就二分找出「刚好塞得下」的字符数并补省略号。
    /// 调用时机：textCard 生成正文前。
    private static func fit(_ text: String, attrs: [NSAttributedString.Key: Any],
                            width: CGFloat, maxHeight: CGFloat)
        -> (text: String, height: CGFloat, truncated: Bool, total: Int) {
        let total = text.count
        let full = measure(text, attrs: attrs, width: width)
        // 统一加 6 点安全余量，和绘制时保持同一套算法，避免「量得下、画不下」
        let fullNeeded = ceil(full.height) + 6
        if fullNeeded <= maxHeight {
            return (text, fullNeeded, false, total)
        }

        // 超长文本先砍到 12000 字符再二分，否则每次排版都太慢
        let working = text.count > 12000 ? String(text.prefix(12000)) : text
        var low = 0
        var high = working.count
        var best = ""
        // 二分 18 次足够精确到单字
        for _ in 0..<18 {
            let mid = (low + high + 1) / 2
            let candidate = String(working.prefix(mid)) + "…"
            if ceil(measure(candidate, attrs: attrs, width: width).height) + 6 <= maxHeight {
                best = candidate
                low = mid
            } else {
                high = mid - 1
            }
            if low >= high { break }
        }
        if best.isEmpty { best = "…" }
        return (best, ceil(measure(best, attrs: attrs, width: width).height) + 6, true, total)
    }

    /// 压缩连续空行，避免复制带一堆空行的文本时卡片被拉得很长。
    /// 调用时机：textCard 入口处。
    private static func tidy(_ text: String) -> String {
        var out: [String] = []
        var blanks = 0
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                if blanks <= 1 { out.append("") }
            } else {
                blanks = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func smallAttrs(_ pal: Palette, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: pal.secondary,
        ]
    }

    /// 千分位，让「1,234 字符」比「1234 字符」好读。
    private static var numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func grouped(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

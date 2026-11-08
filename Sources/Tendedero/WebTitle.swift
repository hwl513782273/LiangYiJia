import Foundation

/// 抓网页标题，给链接卡当大字用。
/// 调用时机：ClipboardWatcher 识别出链接之后，在后台队列里先调它，
/// 拿到标题再交给 CardRenderer 画卡。抓不到就用 nil，链接卡自动降级成「域名 + 地址」。
///
/// 为什么要限时：这是全自动监听，用户复制完一个链接就指望马上看到卡片，
/// 不能因为某个站慢就把整条队列堵住。所以有超时，到点就放弃。
///
/// 本文件从「万能挂载」工程原样搬入，逻辑未改。
enum WebTitle {

    /// 同步抓取标题，必须在后台线程调用（内部用信号量阻塞等待）。
    /// 超时 2.5 秒：实测国内站点 0.2 秒就能回，GitHub 这类要 6 秒。
    /// 抓不到就用 nil 降级，卡片上仍然有完整地址，信息不丢。
    static func fetch(_ url: URL, timeout: TimeInterval = 2.5) -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // 标题一定在 <head> 里，只要前 64KB 就够，不用下整页（大页面能省好几秒）
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        // 有些站点对没有 UA 的请求直接返回 403，伪装成 Safari
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        // 用 class 包一层，避免并发闭包里直接改局部变量（Swift 6 会报错）
        final class Box: @unchecked Sendable { var title: String? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            // 只读前 512KB，标题一定在 <head> 里，没必要下整页
            guard let data, data.count <= 512 * 1024 else { return }
            box.title = parseTitle(data)
        }
        task.resume()

        // 比请求超时多等半秒，等不到就取消
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return nil
        }
        return box.title
    }

    /// 把网页字节解成字符串。
    /// 调用时机：parseTitle 拿到原始字节后第一件事。
    ///
    /// 这里踩过一个坑：Range 请求只取前 64KB，很可能正好切在一个多字节字符中间，
    /// 于是 `String(data:encoding:.utf8)` 因为「有一个坏字节」把**整段**判为失败，
    /// 一路回退到 Latin-1，标题里的中文全变成「å‚´å­—ç¢—」这种乱码。
    /// 所以先宽容解码：只把坏的那一两个字节换成 U+FFFD，别让一颗老鼠屎坏了一锅汤。
    private static func decode(_ data: Data) -> String? {
        // 1. 干净的 UTF-8，最好情况
        if let text = String(data: data, encoding: .utf8) { return text }

        // 2. 有少量坏字节的 UTF-8：强制解码，坏字节 < 2% 就认它
        let lenient = String(decoding: data, as: UTF8.self)
        let broken = lenient.unicodeScalars.reduce(0) { $0 + ($1 == "\u{FFFD}" ? 1 : 0) }
        if broken == 0 || broken * 50 <= lenient.unicodeScalars.count { return lenient }

        // 3. 真不是 UTF-8，再按 GB18030 试（不少中文站仍是这个编码）
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }

        // 4. 最后的兜底：Latin-1 永远不会失败，但解出来很可能就是乱码
        return String(data: data, encoding: .isoLatin1)
    }

    /// 从 HTML 字节里抠出 <title>。
    /// 调用时机：WebTitle.fetch 的网络回调里。
    private static func parseTitle(_ data: Data) -> String? {
        guard let html = decode(data) else { return nil }

        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }

        var title = String(html[titleRange])
        title = decodeEntities(title)
        // 换行、连续空白压成一个空格
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }
        // 太长的标题截断，卡片上放不下
        if title.count > 120 { title = String(title.prefix(120)) + "…" }
        return title
    }

    /// 解开 HTML 实体，否则卡片上会出现 &amp; 这种原始写法。
    /// 调用时机：parseTitle 拿到原始标题后。
    private static func decodeEntities(_ text: String) -> String {
        let map: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&middot;": "·",
        ]
        var out = text
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // 处理 &#123; 这种数字实体
        if let regex = try? NSRegularExpression(pattern: "&#(\\d{1,6});") {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            // 从后往前替换，避免位置错乱
            for match in matches.reversed() {
                guard let codeRange = Range(match.range(at: 1), in: out),
                      let code = UInt32(out[codeRange]),
                      let scalar = Unicode.Scalar(code) else { continue }
                let full = Range(match.range, in: out)!
                out.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return out
    }
}

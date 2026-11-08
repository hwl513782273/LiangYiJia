import AppKit

/// 线挂在哪块显示屏上。三档：跟随鼠标（默认）/ 主显示器 / 指定某块显示器。
///
/// 为什么记 UUID 而不是记 NSScreen：NSScreen 每次显示器变动都会重建，
/// CGDirectDisplayID 在拔插、换接口后也可能变；显示器 UUID 在拔插之间不变，
/// 所以外接屏拔掉再插回来还能认出是同一块，自动把线搬回去。
enum ScreenChoice {

    /// UserDefaults 里存的值：
    /// 没有这个键 = 跟随鼠标；"main" = 主显示器；"uuid:<显示器UUID>" = 指定某块屏。
    private static let key = "lineScreen"
    private static let mainValue = "main"
    private static let uuidPrefix = "uuid:"

    enum Mode: Equatable {
        /// 线跟着鼠标走：鼠标在哪块屏，线就在哪块屏（本改版之前的唯一行为）。
        case pointer
        /// 永远钉在系统主显示器上（带菜单栏、坐标原点那块）。
        case main
        /// 钉在一块具体的显示器上，按显示器 UUID 记。
        case display(String)
    }

    /// 用户当前的设置。调用时机：菜单勾选状态、placeOnScreen 决定落点。
    static var mode: Mode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .pointer }
            if raw == mainValue { return .main }
            if raw.hasPrefix(uuidPrefix) {
                let id = String(raw.dropFirst(uuidPrefix.count))
                if !id.isEmpty { return .display(id) }
            }
            return .pointer
        }
        set {
            switch newValue {
            case .pointer:
                // 跟随鼠标是默认值，不留键，省得将来默认值变了还被旧键钉住
                UserDefaults.standard.removeObject(forKey: key)
            case .main:
                UserDefaults.standard.set(mainValue, forKey: key)
            case .display(let id):
                UserDefaults.standard.set(uuidPrefix + id, forKey: key)
            }
        }
    }

    /// 线是否被钉在某块屏上（主显示器也算钉住）。
    /// 钉住的意思是：不再跟着指针换屏，新内容也不会把线拽到别的屏去。
    static var isPinned: Bool { mode != .pointer }

    // MARK: 认屏

    /// 一块屏在拔插之间不变的标识。
    static func stableID(for screen: NSScreen) -> String? {
        guard let number = displayID(of: screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 两块 NSScreen 是不是同一块物理屏。
    ///
    /// 不能直接用 `==`：`NSScreen.screens` 每次调用都可能给出新的包装对象，
    /// 同一个显示器比较下来会是不相等。按 displayID 比才可靠。
    static func isSame(_ a: NSScreen?, _ b: NSScreen?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard let x = displayID(of: a), let y = displayID(of: b) else { return a === b }
        return x == y
    }

    /// 主显示器：系统里带菜单栏、坐标原点所在的那块。
    ///
    /// 特意不用 `NSScreen.main`——那个是「当前有键盘焦点」的屏，
    /// 会跟着窗口焦点跑，用户勾了「主显示器」却看到线换屏。
    static var mainDisplay: NSScreen? { NSScreen.screens.first }

    /// 这一刻线应该挂在哪块屏上。
    /// - Parameter preferred: 调用方更希望的屏，比如截图所在的那块。
    ///   只有「跟随鼠标」时会采纳；钉住了就一律听设置的。
    static func target(preferring preferred: NSScreen? = nil) -> NSScreen? {
        switch mode {
        case .pointer:
            return preferred ?? LinePanel.screenUnderPointer()
        case .main:
            return mainDisplay
        case .display(let id):
            // 钉住的那块被拔掉了：先回落到主显示器，**不改设置**，
            // 这样插回来时下一次 placeOnScreen 会自动搬回去。
            return NSScreen.screens.first { stableID(for: $0) == id } ?? mainDisplay
        }
    }

    // MARK: 菜单

    /// 菜单里那条子菜单要列的名字。系统给的 `localizedName` 已经本地化，直接用。
    /// 两块同型号外接屏会重名（都叫 "DELL U2720Q"），这时补上像素分辨率区分，
    /// 否则用户没法知道自己勾的是左边那块还是右边那块。
    ///
    /// 有的显示器（本机实测就是）`localizedName` 返回空字符串，
    /// 菜单项会变成一条空白，所以空名要按顺序兜底成「显示器 1 / 2」。
    static func menuEntries() -> [(screen: NSScreen, title: String)] {
        let screens = NSScreen.screens
        let names = screens.map(\.localizedName)
        return screens.enumerated().map { index, screen in
            let raw = screen.localizedName
            var base = raw.isEmpty ? String(format: L("Display %d"), index + 1) : raw
            if !raw.isEmpty, names.filter({ $0 == raw }).count > 1 {
                let points = screen.frame.size
                let scale = screen.backingScaleFactor
                let w = Int(points.width * scale)
                let h = Int(points.height * scale)
                base += " — \(w)×\(h)"
            }
            return (screen, base)
        }
    }
}

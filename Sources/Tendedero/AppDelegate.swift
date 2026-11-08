import AppKit
import Carbon
import Combine
import Quartz
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // MARK: 悬停预览（本 fork 新增）

    /// 鼠标当前停在哪张卡上。用来判断「还是同一张」和「换了一张」。
    private var hoverID: UUID?
    /// 鼠标是何时开始停在这张卡上的。停够 hoverDelay 才弹预览，
    /// 否则鼠标扫过整条线会一路弹窗。
    private var hoverSince: Date?

    /// 悬停多久才弹出预览。0.35 秒：比一次匆忙划过长，比「我想看看」短。
    private static let hoverDelay: TimeInterval = 0.35

    /// 鼠标离开卡片后，先等这么久再收预览。
    /// 卡片和预览之间有一点缝，鼠标挪过去时会短暂地「既不在卡片上也不在预览上」，
    /// 不留这个宽限，预览就会在指针还没到之前先消失。
    private static let hoverLeaveGrace: TimeInterval = 0.3

    /// 鼠标是何时离开卡片的（用于上面那个宽限）。
    private var hoverLeaveSince: Date?

    /// 鼠标停在卡片上时临时注册的「裸 Delete」热键。
    /// 鼠标一离开就注销，所以平时 Delete 还是 Delete。
    /// 用 Carbon 热键而不是全局键盘监听：热键不需要任何系统权限。
    private var hoverDeleteKeys: [HotKey] = []

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    /// 一直显示：线一直挂在屏幕顶上，不再因为指针离开而自动收回。
    /// 调用时机：菜单里勾选时写入；tick / itemsChanged / 启动恢复时读取。
    ///
    /// 默认关。开了之后，手动点菜单「收起线」仍然能收起来——
    /// 那种情况属于用户明确要求，不该被这个开关拽回来。
    static var alwaysShown: Bool {
        get { UserDefaults.standard.bool(forKey: "alwaysShown") }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysShown") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        // sizingOptions 是 macOS 13 才有的；12 上不设，沿用系统默认行为。
        // 设空集的本意是「别让内容反过来撑大 host」，而 12 上默认会更新 intrinsicContentSize；
        // 但面板尺寸由 placeOnScreen 定好、host 跟着面板走，所以不设也能保持布局。
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        // 定时器总是开着，不再受开关控制：
        // 关掉「挂上复制的内容」只是不再挂新东西，
        // 但「点文字卡把原文复制回来」还得靠它盯着剪贴板。
        clipboardWatcher.start()

        registerShortcut()

        setUpStatusItem()
        watchMenuBarClicks()

        // Hang on Tendedero, in the menu of images in Finder and other apps.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Share.shared.clearAll()
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onHold = { [weak self] id in self?.hold(id) }
        line.onHangBack = { id in Held.hangBack(id) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        // 勾了「一直显示」的话，即便这次一条都没有，绳子也要摆出来。
        if line.liveCount > 0 || Self.alwaysShown { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh()
                        self?.keepOnActiveSpace()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
        Share.shared.clearAll()
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// 挂不挂剪贴板内容是 opt in，只能从菜单栏打开。
    /// 注意这里不 stop 定时器：关掉只是不再挂新内容，
    /// 「点文字卡还原原文」还要用同一个定时器，停了就点不出文字了。
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        Held.forget(except: Set(line.items.filter { !$0.falling && $0.held }.map(\.id)))
        // 「一直显示」时空气也要留着：绳子本来就该在那儿，卡片取完了它也不该消失。
        guard line.liveCount == 0, !keepOpen, !Self.alwaysShown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        // 一直显示：放下来就待着，不用「闪一下再收回」那套
        if Self.alwaysShown {
            reveal()
        } else if Self.peeksAtNew {
            reveal(peekFor: 2.5)
        }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        // Already hanging: a photo put back with ⌘Z comes out of the Trash
        // into the folder, and the watcher sees it arrive. It must not pull
        // the line over to the screen it was first taken on.
        guard !line.items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling })
        else { return }
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        // A screenshot macOS took already played its shutter, so it hangs
        // without a chime of its own. Copied images and watched folders,
        // which come with no sound, keep it.
        guard let id = line.hang(url, quietly: from != nil, flying: from != nil) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, !Self.reducesMotion, CaptureFlight.flightsInProgress < 2,
              let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    /// Reduce motion in Accessibility settings: photos land and leave
    /// without flying across the screen or falling down it.
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // 线收着（或者开了减弱动态）时掉落不画出来，只从线上消失
            log.notice("掉落动画跳过：present=\(self.isPresent, privacy: .public) revealed=\(self.isRevealed, privacy: .public) flying=\(item.flying, privacy: .public)")
            return
        }
        log.notice("掉落动画开播：x=\(card.minX, privacy: .public)")
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), pinned: item.kept, on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
            // 一直显示：窗口一被放回来（比如全屏 App 退出、切回桌面）就把线也放下，
            // 否则它会一直停在上一次被全屏挡住时那个「收着」的状态。
            if Self.alwaysShown, !isRevealed { reveal() }
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The line is one window on every Space. After a long time running,
    /// macOS can leave it bound to a single Space, where ordering it in does
    /// nothing on the others while captures keep arriving (#80). Quitting and
    /// opening the app again fixes it because the window is new, so do the
    /// same here: a fresh window with the same contents, in the same place.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("The line was not on the active Space; making its window again")
        let old = panel!
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = LinePanel(content: content ?? NSView())
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent {
                panel.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    /// 「一直显示」刚被切换，立刻让它生效。
    /// 调用时机：菜单里点那一项之后。
    ///
    /// 打开：马上把线放下来（哪怕线上是空的），不然要等下一次复制才有反应。
    /// 关掉：只是清掉「指针没离开」的假状态，收不收交给 tick 照老规矩判断，
    /// 不在这里硬收——指针可能正停在线上，硬收会显得莫名其妙。
    private func applyAlwaysShown() {
        if Self.alwaysShown {
            panel.placeOnScreen()
            updateCapacity()
            wanted = true
            refresh()
            reveal()
        } else {
            awaySince = nil
        }
        updateStatusIcon()
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
        holdPutBackKey(false)
        holdPhotoKeys(over: nil)
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// The part of the menu bar that brings the line down: the middle third,
    /// so the menus on the left and the icons on the right stay easy to reach.
    static func revealBand(of screen: NSScreen) -> NSRect {
        let bar = menuBarBand(of: screen)
        let width = bar.width / 3
        return NSRect(x: bar.midX - width / 2, y: bar.minY, width: width, height: bar.height)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }
        let inRevealBand = screenUnderPointer.map { NSMouseInRect(mouse, Self.revealBand(of: $0), false) } ?? false

        guard isRevealed else {
            holdPutBackKey(false)
            holdPhotoKeys(over: nil)
            // 线收起来了，预览也跟着收
            endHover()
            line.closeGaps()
            // Resting in the middle of the menu bar brings the line down on
            // that screen. Pushing against the top edge is part of it, and it
            // also works when another display sits above and the pointer
            // never stops.
            // An empty line stays up there: only the shortcut and the menu
            // bring it down on purpose.
            if line.liveCount > 0, Self.opensFromMenuBar, let screen = screenUnderPointer,
               inRevealBand, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }
        holdPutBackKey(inside)
        let hovered = inside ? photo(under: mouse) : nil
        holdPhotoKeys(over: hovered)
        // 悬停放大预览：停够时间就弹出原图 / 原文
        updateHover(hovered, mouse: mouse)
        // Gaps left by discarded photos close once the pointer moves away.
        if !inside { line.closeGaps() }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu || Share.shared.isOpen
            || line.pressedID != nil || now < peekUntil
        // 勾了「一直显示」就永远当作指针还在线上：awaySince 不累加，永不收回。
        if inside || busy || Self.alwaysShown {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.items.count > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Holding

    /// Takes a photo off the line to hold in front of you. The line goes
    /// up, so it is out of the way of the photo you are looking at.
    private func hold(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id && !$0.falling && !$0.held }) else { return }
        line.setHeld(id, true)
        Held.show(id, url: item.url, line: line) { [weak self] id, frame in self?.hangBack(id, from: frame) }
    }

    /// Back onto its clip: the line comes down and the photo flies home.
    private func hangBack(_ id: UUID, from frame: CGRect) {
        line.setHeld(id, false)
        comeDown(on: NSScreen.screens.first { $0.frame.intersects(frame) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: frame)
        }
    }

    // MARK: Hang on Tendedero

    /// The service macOS lists for images in Finder and elsewhere. What
    /// you hang yourself is pinned, and the line comes down to show it.
    @objc func hangOnLine(_ pasteboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        comeDown(on: nil)
        var any = false
        for url in urls where line.hangKept(url) { any = true }
        if !any { NSSound.beep() }
    }

    // MARK: Keys over a photo

    /// Delete and Space while the pointer rests on a photo: Delete does what
    /// its corner button does, Space takes a quick look, as in Finder. Like
    /// ⌘Z, they are borrowed as hot keys only then, so every other app keeps
    /// them.
    private var photoKeys: [HotKey] = []
    private var photoKeysFor: UUID?

    private func holdPhotoKeys(over id: UUID?) {
        let id = id.flatMap { id in line.items.first { $0.id == id && !$0.falling && !$0.held }?.id }
        guard id != photoKeysFor else { return }
        photoKeysFor = id
        photoKeys = []
        guard let id else { return }
        photoKeys = [
            HotKey(Shortcut(keyCode: kVK_Delete, modifiers: [], key: "\u{8}")) { [weak self] in
                self?.line.pressCorner(id)
            },
            HotKey(Shortcut(keyCode: kVK_Space, modifiers: [], key: " ")) { [weak self] in
                self?.quickLookToggle(id)
            },
        ].compactMap { $0 }
    }

    /// The photo whose card is under the pointer, if any.
    private func photo(under mouse: NSPoint) -> UUID? {
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.first { $0.value.contains(flipped) }?.key
    }

    // MARK: 悬停放大预览（本 fork 新增）

    /// 光标停在同一张卡上够久，就在卡片下方弹出放大预览；换了卡或移开就收起。
    /// 调用时机：tick() 每帧调用，参数是这一帧鼠标下的卡片。
    private func updateHover(_ id: UUID?, mouse: NSPoint) {
        // 调试开关：HOVER_DEMO=1 时无视鼠标，直接对第一张卡显示预览。
        // 用途是在没有辅助功能权限的环境里验收预览窗渲染，正式运行时这个变量不存在。
        if ProcessInfo.processInfo.environment["HOVER_DEMO"] == "1" {
            if let first = line.items.first, let card = cardScreenRect(first.id) {
                HoverPreview.shared.show(url: first.url, below: card)
            }
            return
        }

        // 拖动、右键菜单、正按住卡片时不要弹，会碍事
        if GrabView.isDragging || GrabView.isShowingMenu || line.pressedID != nil {
            endHover()
            return
        }

        // 鼠标已经移到预览窗上：保持现状，也不重新计时，
        // 否则鼠标一离开卡片预览就闪没了，根本没法看
        if HoverPreview.shared.contains(mouse) {
            hoverLeaveSince = nil
            return
        }

        if let id {
            // 指针在卡片上
            hoverLeaveSince = nil
            if id != hoverID {
                hoverID = id
                hoverSince = Date()
                // 停在哪张上，就把 Delete 临时绑到这张上
                armHoverDelete()
            }
            guard let since = hoverSince,
                  Date().timeIntervalSince(since) >= Self.hoverDelay,
                  let card = cardScreenRect(id),
                  let item = line.items.first(where: { $0.id == id }) else { return }
            HoverPreview.shared.show(url: item.url, below: card)
            return
        }

        // 指针不在任何卡片上：Delete 还给系统
        hoverID = nil
        hoverSince = nil
        disarmHoverDelete()
        guard HoverPreview.shared.isShowing else { return }
        // 留一点宽限，别让鼠标划过卡片间的空隙时预览一闪一闪
        let since = hoverLeaveSince ?? Date()
        hoverLeaveSince = since
        if Date().timeIntervalSince(since) >= Self.hoverLeaveGrace {
            HoverPreview.shared.hide()
            hoverLeaveSince = nil
        }
    }

    /// 收起预览，并清掉悬停状态。
    private func endHover() {
        hoverID = nil
        hoverSince = nil
        hoverLeaveSince = nil
        disarmHoverDelete()
        HoverPreview.shared.hide()
    }

    // MARK: 按 Delete 删除悬停的卡片（本 fork 新增）

    /// 鼠标停到卡片上时，临时把 Delete 注册成热键；离开就注销。
    /// 调用时机：updateHover 发现悬停的卡片变了（换了一张，或从没有到有）。
    ///
    /// 为什么用 Carbon 热键而不是全局键盘监听：
    /// 1. 全局监听要「输入监控」权限。本项目是 ad-hoc 签名，每次重新编译签名指纹都变，
    ///    系统把它当成另一个 App，授权当场作废——实测重新打包后立刻变成未授权，
    ///    等于每改一次代码就得让用户去系统设置重勾一次。热键不需要任何权限。
    /// 2. 热键会吃掉这一次按键，不会同时把前台文档里的字也删掉。
    ///    鼠标停在卡片上按 Delete，本来就是要删这张卡，吃掉正是想要的。
    private func armHoverDelete() {
        guard hoverDeleteKeys.isEmpty else { return }
        // 51 = Backspace（Mac 键盘上印着 delete 的那个），117 = Fn+Delete
        for code in [kVK_Delete, kVK_ForwardDelete] {
            let shortcut = Shortcut(keyCode: code, modifiers: [], key: "")
            let key = HotKey(shortcut, action: { [weak self] in
                guard let self, let id = self.hoverID else { return }
                self.removeHovered(id)
            })
            if let key { hoverDeleteKeys.append(key) }
        }
    }

    /// 注销 Delete 热键，把 Delete 还给系统。
    /// 调用时机：鼠标离开卡片、线收起、开始拖动。
    private func disarmHoverDelete() {
        // HotKey 的 deinit 自己会 UnregisterEventHotKey，清空数组就够了
        guard !hoverDeleteKeys.isEmpty else { return }
        hoverDeleteKeys.removeAll()
    }

    /// 删掉悬停的那张卡：文件进废纸篓，卡片按原版动画掉下去。
    /// 调用时机：Delete 热键触发。
    ///
    /// 文字卡和链接卡旁边有一份原文 .txt，原版不认识它，得顺手清掉，
    /// 否则文件夹里会积一堆没有主人的 txt。只在卡片真的删掉了才删，
    /// 不然卡片还在、原文没了，点它就没东西可还原。
    private func removeHovered(_ id: UUID) {
        // 先收预览，否则卡片掉下去时那个大窗还挂在原地
        endHover()
        // 原文存在 PNG 的扩展属性里，文件一进废纸篓就全带走了，不用另外清理
        line.trash(id)
    }

    /// 某张卡在屏幕上的位置。
    /// hitRects 存的是面板坐标翻转后的矩形（y 从顶往下数），
    /// 这里翻回普通坐标，再加上面板原点，才是屏幕坐标。
    private func cardScreenRect(_ id: UUID) -> CGRect? {
        guard let r = line.hitRects[id] else { return nil }
        let local = CGRect(x: r.minX,
                           y: panel.frame.height - r.maxY,
                           width: r.width, height: r.height)
        return local.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Space opens Quick Look, and closes it again if it is already open.
    private func quickLookToggle(_ id: UUID) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            line.quickLook(id)
        }
    }

    // MARK: Putting back

    /// ⌘Z while the pointer is on the line. The line never takes the
    /// keyboard, so it only borrows ⌘Z then, as a hot key. Everywhere else
    /// ⌘Z stays the undo of the app you are in.
    private var putBackKey: HotKey?

    /// Set when another app holds ⌘Z, so it is not asked for again on every
    /// tick, only the next time the pointer comes to the line.
    private var putBackKeyRefused = false

    private func holdPutBackKey(_ hold: Bool) {
        guard hold && line.canPutBack else {
            putBackKey = nil
            putBackKeyRefused = false
            return
        }
        guard putBackKey == nil, !putBackKeyRefused else { return }
        putBackKey = HotKey(Shortcut.putBack) { [weak self] in self?.putBack() }
        putBackKeyRefused = putBackKey == nil
    }

    /// From the menu the line is usually up, so it comes down for a moment
    /// to show the photos going back.
    private func putBack() {
        if !isRevealed {
            panel.placeOnScreen()
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        }
        line.putBack()
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    NSSound.beep()
                    Shortcut.current = previous
                }
            }
            self.registerShortcut()
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits, Line.keepOnLine ?? fits)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched. It is dimmed while the
    /// line is empty, so resting in the menu bar and seeing nothing come down
    /// does not look broken.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let count = line.liveCount
        // 朗读用的名字跟着 App 走：bundle 里叫「晾衣架」，这里就不能残留 Tendedero，
        // 否则旁白念出来是别人的名字。
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "晾衣架"
        let description = on ? L("Tendedero, hanging copied images") : appName
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        let image = NSImage(systemSymbolName: on ? "tshirt.fill" : "tshirt",
                            accessibilityDescription: "\(description), \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = count == 0
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        // 一直显示：勾上之后线常驻屏幕顶，不再因为指针离开而收回
        let alwaysItem = ClosureMenuItem(L("Always show")) { [weak self] in
            AppDelegate.alwaysShown.toggle()
            self?.applyAlwaysShown()
        }
        alwaysItem.state = Self.alwaysShown ? .on : .off
        alwaysItem.toolTip = L("The line stays on screen and never tucks away")
        menu.addItem(alwaysItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let putBackItem = ClosureMenuItem(L("Put back"), key: "z") { [weak self] in
            self?.putBack()
        }
        putBackItem.isEnabled = line.canPutBack
        menu.addItem(putBackItem)

        if !Held.heldIDs.isEmpty {
            menu.addItem(ClosureMenuItem(L("Hang everything back")) { Held.hangEverythingBack() })
        }

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests in the menu bar")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = AppDelegate.opensAtLogin ? .on : .off
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        menu.addItem(ClosureMenuItem(L("Check for Updates…")) {
            NSWorkspace.shared.open(AppDelegate.updatesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// tendedero.app with the running version, and the menus' language when
    /// the website has it too, so the page answers in the same words.
    private static var updatesURL: URL {
        var components = URLComponents(string: "https://tendedero.app/")!
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var query = [URLQueryItem(name: "update", value: version)]
        if let language = Bundle.main.preferredLocalizations.first, ["en", "es", "gl", "fr", "pt-BR", "ja", "ko", "zh-Hans"].contains(language) {
            query.append(URLQueryItem(name: "lang", value: language))
        }
        components.queryItems = query
        return components.url!
    }

    private static func toggleLaunchAtLogin() {
        // 原版这里用 SMAppService.mainApp.register()。它要求 App 有正式签名，
        // 本项目是 ad-hoc 签名，每次重编译指纹都变，注册必然抛错。
        // 改成自己维护一个 LaunchAgent：launchd 登录时会自动扫描这个目录，
        // 不需要任何签名，也不需要提前 launchctl load。
        let agent = loginAgentURL
        do {
            if FileManager.default.fileExists(atPath: agent.path) {
                try FileManager.default.removeItem(at: agent)
            } else {
                try loginAgentPlist().write(to: agent, atomically: true, encoding: .utf8)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 登录自启那个 plist 的落点。
    /// 调用时机：菜单里要显示开关状态、以及切换时读写文件。
    static var loginAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.local.liangyijia.plist")
    }

    /// 现在算不算开了自启：只看文件在不在。
    /// 不查 launchctl：那个要特权，查不到还会误判成「没开」。
    static var opensAtLogin: Bool {
        FileManager.default.fileExists(atPath: loginAgentURL.path)
    }

    /// 生成自启配置内容。
    /// 调用时机：切换「登录时打开」把它打开时。
    ///
    /// 只写三个键：多余的键（LimitLoadToSessionType 之类）出问题时是静默失败，
    /// 越少越不容易在登录那一刻莫名不生效。也不写 KeepAlive——写 true 的话
    /// 用户从菜单里退出，launchd 会立刻把它拉回来，像甩不掉。
    private static func loginAgentPlist() -> String {
        // 用当前正在跑的可执行文件路径，而不是写死；App 被挪过位置也对得上
        let exe = Bundle.main.executablePath
            ?? "/Applications/晾衣架.app/Contents/MacOS/晾衣架"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.local.liangyijia</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(exe)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
        </dict>
        </plist>

        """
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}


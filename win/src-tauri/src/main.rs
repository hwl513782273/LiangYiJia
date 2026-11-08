// 用途：晾衣架 Windows 版的主程序。
//       1) 创建贴在屏幕顶端的透明窗口（逐像素透明、永远置顶、不抢焦点、不进 Alt-Tab）
//       2) 轮询系统光标，指针落在某张卡片上时临时取消点击穿透，其余时候整窗穿透
//       3) 监听剪贴板，把文字 / 链接 / 图片发给前端挂到线上
//       4) 托盘图标与菜单（退出）
// 调用时机：开机自启或用户双击 exe 时由系统拉起，之后常驻。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicIsize, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use tauri::{Emitter, Manager, PhysicalPosition, PhysicalSize};

/// 窗口高度（逻辑点）。比带子本身（约 210）高，给掉落的卡片留出下坠空间：
/// 多出来的那片完全透明且点击穿透，不会挡住桌面上的任何操作。
const WINDOW_HEIGHT: f64 = 640.0;

/// 指针落在卡片外接矩形外扩这么多点以内，就认为「在卡片上」。
/// 稍留余量，避免手抖时穿透状态来回跳。
const HIT_SLOP: f64 = 2.0;

/// 前端每帧报上来的卡片矩形（窗口内 CSS 坐标：x, y, w, h）。
static HIT_RECTS: Mutex<Vec<[f64; 4]>> = Mutex::new(Vec::new());

/// 原生窗口句柄，光标线程要用它切穿透样式。
static HWND_RAW: AtomicIsize = AtomicIsize::new(0);

/// 当前是否处于「整窗穿透」状态，避免重复调用 SetWindowLongPtr。
static CLICK_THROUGH: AtomicBool = AtomicBool::new(true);

/// 剪贴板内容的指纹，用来判断「变了没有」。
static CLIP_HASH: AtomicU64 = AtomicU64::new(0);

/// 窗口左上角的物理坐标与缩放系数。
/// 启动时算一次存下来：光标线程每秒要跑 60 圈，如果每圈都去问系统窗口位置，
/// 循环会被拖慢到几十毫秒一轮，短促的点击就被漏掉了（实测过）。
static WIN_ORIGIN_X: AtomicI32 = AtomicI32::new(0);
static WIN_ORIGIN_Y: AtomicI32 = AtomicI32::new(0);
static WIN_SCALE_BITS: AtomicU64 = AtomicU64::new(0);

#[cfg(target_os = "windows")]
mod platform {
    use windows_sys::Win32::Foundation::{HWND, POINT};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetCursorPos, GetWindowLongPtrW, SetLayeredWindowAttributes, SetWindowLongPtrW, SetWindowPos,
        GWL_EXSTYLE,
        HWND_TOPMOST, LWA_ALPHA, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
        WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT,
    };

    /// tauri 用的是 windows crate 的 HWND（isize 包装），windows-sys 用的是裸指针。
    /// 两者内存布局一致，直接按数值转，避免两个 crate 版本互相牵制。
    pub fn as_hwnd(raw: isize) -> HWND {
        raw as HWND
    }

    /// 扩展样式在 windows-sys 里是 u32（WINDOW_EX_STYLE），不是 i32。
    fn ex_style(hwnd: HWND) -> u32 {
        unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32 }
    }

    fn set_ex_style(hwnd: HWND, style: u32) {
        unsafe {
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style as isize);
            // 改完扩展样式必须让窗口重算边框，否则新样式不生效。
            SetWindowPos(
                hwnd,
                std::ptr::null_mut(),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED,
            );
        }
    }

    /// 一次性把窗口调成「工具窗」形态：
    /// - WS_EX_TOOLWINDOW  不出现在 Alt-Tab 和任务栏里（skipTaskbar 只管任务栏）
    /// - WS_EX_NOACTIVATE  点它也不会把前台程序切走，这是「不抢焦点」的关键
    /// - HWND_TOPMOST      永远压在普通窗口上面
    pub fn apply(hwnd: HWND) {
        let style = ex_style(hwnd) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
        set_ex_style(hwnd, style);
        unsafe {
            SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }

    /// 切换整窗点击穿透。
    /// 穿透靠 WS_EX_LAYERED + WS_EX_TRANSPARENT 这一对；分层窗口必须显式给一个
    /// 不透明度，否则窗口会变成全透明（看不见），所以顺手设成 255。
    pub fn set_click_through(hwnd: HWND, through: bool) {
        let mut style = ex_style(hwnd);
        if through {
            style |= WS_EX_LAYERED | WS_EX_TRANSPARENT;
            unsafe {
                SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
            }
        } else {
            style &= !WS_EX_TRANSPARENT;
        }
        set_ex_style(hwnd, style);
    }

    /// 鼠标左键当前是否按下。用 GetAsyncKeyState 取最高位（0x8000 = 正被按住）。
    ///
    /// 为什么要自己查而不用 DOM 的 click：窗口带 WS_EX_NOACTIVATE，点击不会激活它，
    /// WebView2 因此收不到点击事件（实测前端一次都没触发）。自己轮询按键状态最稳，
    /// 而且和「指针在哪」用的是同一套轮询。
    pub fn left_button_down() -> bool {
        unsafe { (GetAsyncKeyState(VK_LBUTTON as i32) as u16 & 0x8000) != 0 }
    }

    /// 系统光标的物理坐标。屏幕左上角是 (0,0)。
    pub fn cursor_pos() -> (i32, i32) {
        let mut p = POINT { x: 0, y: 0 };
        unsafe {
            GetCursorPos(&mut p);
        }
        (p.x, p.y)
    }
}

/// 把启动时的窗口/屏幕实测值写到 %TEMP%\liangyijia.log。
/// 用途：Windows 上没法开 DevTools，多屏与 DPI 相关的怪问题只能靠这份日志对账。
/// 是否输出诊断日志。设 LIANGYIJIA_DEBUG=1 才开会写光标与按键的逐秒记录；
/// 正常运行时只留启动两行和错误，不会往 %TEMP% 里无限增长。
fn debug_on() -> bool {
    std::env::var("LIANGYIJIA_DEBUG").map(|v| v == "1").unwrap_or(false)
}

fn log_line(msg: &str) {
    use std::io::Write;
    let path = std::env::temp_dir().join("liangyijia.log");
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{msg}");
    }
}

/// 前端判断指针不在卡片上时调用，把整窗变成点击穿透，桌面上的点按照常落到下面的程序。
#[tauri::command]
fn set_click_through(window: tauri::WebviewWindow, through: bool) {
    CLICK_THROUGH.store(through, Ordering::Relaxed);
    #[cfg(target_os = "windows")]
    {
        if let Ok(h) = window.hwnd() {
            platform::set_click_through(platform::as_hwnd(h.0 as isize), through);
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = window;
    }
}

/// 前端每帧把卡片的实际外接矩形报上来（窗口内 CSS 坐标）。
/// 光标线程拿它做命中判断，决定要不要临时取消穿透。
#[tauri::command]
fn set_hit_rects(rects: Vec<[f64; 4]>) {
    if let Ok(mut guard) = HIT_RECTS.lock() {
        *guard = rects;
    }
}

/// 开发期开关：带环境变量 LIANGYIJIA_DEMO=1 启动时，前端会塞几张示例卡片。
#[tauri::command]
fn demo_mode() -> bool {
    std::env::var("LIANGYIJIA_DEMO").map(|v| v == "1").unwrap_or(false)
}

/// 前端写日志用。Windows 上开不了 DevTools，前端出问题时只能靠这条路把信息带出来。
#[tauri::command]
fn js_log(msg: String) {
    log_line(&format!("js: {msg}"));
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            set_click_through,
            set_hit_rects,
            js_log,
            demo_mode,
            quit_app
        ])
        .setup(|app| {
            let window = app
                .get_webview_window("line")
                .expect("窗口 line 必须在 tauri.conf.json 里定义");

            // 铺满整块屏幕的顶端。
            // 注意：tauri.conf.json 里的 width/height 是「逻辑点」，在高 DPI 屏幕上会被
            // 系统再乘一次缩放系数（本机 200%，1440 点就变成 2880 物理像素），窗口因此比
            // 屏幕还宽，最右边几张卡片直接被推到屏幕外。所以这里必须按 monitor 的
            // 物理像素重新设一次尺寸。
            let current = window.current_monitor().ok().flatten();
            let primary = window.primary_monitor().ok().flatten();
            log_line(&format!(
                "start scale={:?} current={:?} primary={:?}",
                window.scale_factor(),
                current.as_ref().map(|m| (m.size(), m.position(), m.scale_factor())),
                primary.as_ref().map(|m| (m.size(), m.position(), m.scale_factor())),
            ));

            if let Some(monitor) = current.or(primary) {
                let scale = monitor.scale_factor();
                let size = monitor.size();
                let pos = monitor.position();
                let band = (WINDOW_HEIGHT * scale).round() as u32;
                let resized = window
                    .set_size(PhysicalSize::new(size.width, band))
                    .and_then(|_| window.set_position(PhysicalPosition::new(pos.x, pos.y)));
                WIN_ORIGIN_X.store(pos.x, Ordering::Relaxed);
                WIN_ORIGIN_Y.store(pos.y, Ordering::Relaxed);
                WIN_SCALE_BITS.store(scale.to_bits(), Ordering::Relaxed);
                log_line(&format!(
                    "applied size={}x{} pos={},{} err={:?}",
                    size.width, band, pos.x, pos.y, resized.err()
                ));
            } else {
                log_line("no monitor reported, keep config size");
            }

            #[cfg(target_os = "windows")]
            {
                if let Ok(h) = window.hwnd() {
                    HWND_RAW.store(h.0 as isize, Ordering::Relaxed);
                    platform::apply(platform::as_hwnd(h.0 as isize));
                    // 启动时先整窗穿透：这时线上往往没有卡片，不该挡住桌面的点击。
                    platform::set_click_through(platform::as_hwnd(h.0 as isize), true);
                }
            }

            // ---- 托盘：没有它这个应用只能进任务管理器才能退出 ----
            {
                use tauri::menu::{Menu, MenuItem};
                use tauri::tray::TrayIconBuilder;

                let show = MenuItem::with_id(app, "show", "显示 / 隐藏", true, None::<&str>)?;
                let quit = MenuItem::with_id(app, "quit", "退出晾衣架", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&show, &quit])?;

                let mut builder = TrayIconBuilder::with_id("main")
                    .tooltip("晾衣架")
                    .menu(&menu)
                    .show_menu_on_left_click(true)
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "quit" => app.exit(0),
                        "show" => {
                            if let Some(w) = app.get_webview_window("line") {
                                let visible = w.is_visible().unwrap_or(true);
                                if visible { let _ = w.hide(); } else { let _ = w.show(); }
                            }
                        }
                        _ => {}
                    });

                if let Some(icon) = app.default_window_icon() {
                    builder = builder.icon(icon.clone());
                }
                if let Err(e) = builder.build(app) {
                    log_line(&format!("tray build failed: {e}"));
                }
            }

            spawn_cursor_watcher(app.handle().clone());
            spawn_clipboard_watcher(app.handle().clone());

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("启动失败：Tauri 运行时出错");
}

/// 光标线程：每 45ms 取一次系统光标位置，换算成窗口内 CSS 坐标后与卡片矩形比对，
/// 在「压在某张卡上」和「压在空白处」之间切换窗口的点击穿透。
///
/// 为什么必须由原生侧轮询：窗口整窗穿透时收不到 mousemove，前端无从知道指针在哪，
/// 只能反过来由系统光标位置去判断。macOS 版用的是同一个思路（NSEvent.mouseLocation）。
fn spawn_cursor_watcher(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let mut last: Option<bool> = None;
        let mut last_log = std::time::Instant::now();
        let mut last_down = false;
        let mut last_pos: Option<(f64, f64)> = None;
        loop {
            // 16ms ≈ 60Hz：既够跟手，也能采到一次正常速度的点击（按住通常 40ms 以上）
            std::thread::sleep(Duration::from_millis(16));

            let Some(window) = app.get_webview_window("line") else { continue };

            #[cfg(target_os = "windows")]
            {
                let raw = HWND_RAW.load(Ordering::Relaxed);
                if raw == 0 {
                    continue;
                }
                let (cx, cy) = platform::cursor_pos();
                let scale = f64::from_bits(WIN_SCALE_BITS.load(Ordering::Relaxed));
                let scale = if scale > 0.0 { scale } else { 1.0 };
                let ox = WIN_ORIGIN_X.load(Ordering::Relaxed);
                let oy = WIN_ORIGIN_Y.load(Ordering::Relaxed);
                let (lx, ly) = ((cx - ox) as f64 / scale, (cy - oy) as f64 / scale);

                // 命中的是「卡片外接矩形」，稍放宽一点
                let on_card = {
                    let rects = HIT_RECTS.lock().map(|g| g.clone()).unwrap_or_default();
                    rects.iter().any(|r| {
                        lx >= r[0] - HIT_SLOP
                            && lx <= r[0] + r[2] + HIT_SLOP
                            && ly >= r[1] - HIT_SLOP
                            && ly <= r[1] + r[3] + HIT_SLOP
                    })
                };

                // 左键按下沿：从「没按」变成「按下」的那一刻，且指针在卡片上
                let down = platform::left_button_down();
                if down && !last_down && on_card {
                    if debug_on() {
                        log_line(&format!("button down at ({lx:.0},{ly:.0})"));
                    }
                    let _ = app.emit("card-click", (lx, ly));
                }
                last_down = down;

                // 只有状态真的变了才动窗口样式，避免每帧都 SetWindowLongPtr
                if last != Some(on_card) {
                    last = Some(on_card);
                    platform::set_click_through(
                        platform::as_hwnd(raw),
                        !on_card,
                    );
                    CLICK_THROUGH.store(!on_card, Ordering::Relaxed);
                }

                // 前端要用指针位置做悬停放大和「叉号」提示。
                // 只有位置真的动了（或命中状态翻转）才发，否则每秒 60 次 IPC 会把循环拖慢。
                let moved = last_pos.map_or(true, |(px, py)| (px - lx).abs() >= 1.0 || (py - ly).abs() >= 1.0);
                if moved || last != Some(on_card) {
                    last_pos = Some((lx, ly));
                    let _ = app.emit("cursor", (lx, ly, on_card));
                }

                // 每秒打一行诊断，排查「指针在卡上但前端没反应」这类问题
                if debug_on() && last_log.elapsed().as_secs() >= 1 {
                    last_log = std::time::Instant::now();
                    let n = HIT_RECTS.lock().map(|g| g.len()).unwrap_or(0);
                    log_line(&format!(
                        "cursor raw=({cx},{cy}) origin=({ox},{oy}) scale={scale:.2} css=({lx:.0},{ly:.0}) rects={n} on_card={on_card}",
                    ));
                }
            }

            #[cfg(not(target_os = "windows"))]
            {
                let _ = (window, &last);
            }
        }
    });
}

/// 剪贴板指纹：FNV-1a，够快，只用来判断「变了没有」。
fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    h
}

fn looks_like_url(s: &str) -> bool {
    let t = s.trim();
    !t.contains('\n')
        && t.len() < 2048
        && (t.starts_with("http://") || t.starts_with("https://"))
}

/// 剪贴板线程：每 600ms 看一次。
/// 顺序是先文字后图片：系统里图片通常没有文字伴随，而复制网页内容时文字优先。
fn spawn_clipboard_watcher(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        use base64::Engine;

        let mut clipboard = match arboard::Clipboard::new() {
            Ok(c) => c,
            Err(e) => {
                log_line(&format!("clipboard unavailable: {e}"));
                return;
            }
        };

        loop {
            std::thread::sleep(Duration::from_millis(600));

            // ---- 文字 / 链接 ----
            if let Ok(text) = clipboard.get_text() {
                let text = text.trim_end_matches(['\r', '\n']).to_string();
                if !text.trim().is_empty() {
                    let h = fnv(text.as_bytes());
                    if h != CLIP_HASH.load(Ordering::Relaxed) {
                        CLIP_HASH.store(h, Ordering::Relaxed);
                        let payload = if looks_like_url(&text) {
                            serde_json::json!({ "kind": "link", "url": text })
                        } else {
                            serde_json::json!({ "kind": "text", "text": text })
                        };
                        let _ = app.emit("clip", payload);
                    }
                    continue;
                }
            }

            // ---- 图片 ----
            if let Ok(img) = clipboard.get_image() {
                let raw = img.bytes.into_owned();
                let h = fnv(&raw);
                if h != CLIP_HASH.load(Ordering::Relaxed) {
                    CLIP_HASH.store(h, Ordering::Relaxed);
                    if let Some(png_bytes) = encode_png(img.width, img.height, &raw) {
                        let b64 = base64::engine::general_purpose::STANDARD.encode(&png_bytes);
                        let payload = serde_json::json!({
                            "kind": "image",
                            "data": format!("data:image/png;base64,{b64}"),
                            "w": img.width,
                            "h": img.height,
                        });
                        let _ = app.emit("clip", payload);
                    }
                }
            }
        }
    });
}

/// 把 arboard 给的 RGBA 原始像素编码成 PNG。体积比 data URL 里塞原始像素小得多。
fn encode_png(w: usize, h: usize, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, w as u32, h as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }
    Some(out)
}

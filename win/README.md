# 晾衣架 · Windows 版

macOS 版的 Windows 重写。**已经是可以跑起来、能挂东西的版本**，但离 macOS 版的功能完整度还有距离。

技术路线是 **Tauri 2**（Rust 外壳 + WebView2 界面）：安装包小、以后能顺带出 Linux、系统能力有现成插件。
界面用 HTML Canvas 逐帧自绘，几何与物理参数照抄 macOS 版，换系统不该觉得「变了个东西」。

---

## 已实现并在 Windows 上实测

测试环境：Windows 11 ARM64（build 22631）虚拟机，2886×1850 @200% 缩放。

| 能力 | 状态 | 实测证据 |
|---|---|---|
| 逐像素透明（无黑底/白底方块） | ✅ | 壁纸与桌面图标透过带子可见 |
| 永远置顶 | ✅ | 最大化的记事本被压在下面，卡片与投影照常绘制 |
| 不抢焦点 / 不进 Alt-Tab | ✅ | `WS_EX_NOACTIVATE` + `WS_EX_TOOLWINDOW` |
| 整窗点击穿透，仅指针在卡片上时取消 | ✅ | 隔带子双击桌面「回收站」→ 回收站窗口被打开 |
| 剪贴板文字 → 文字卡 | ✅ | 复制 `clipboard test 23:06:35` → 卡片上显示同样内容 + 字数 |
| 剪贴板链接 → 链接卡 | ✅ | 标题暂用域名（macOS 版会抓网页标题） |
| 剪贴板图片 → 图片卡 | ✅ 代码已接 | 未单独截图验收 |
| 悬停放大看全文 | ✅ | 被截断的卡（页脚「已截断 · 点开看全文」）悬停后弹出放大卡，全文 56 字完整显示 |
| 悬停出删除叉号 | ✅ | 悬停后左上角出现叉号 |
| 点卡片把原文复制回剪贴板 | ✅ | 两张卡时点左边那张，剪贴板由 `BBB…` 变成 `AAA…` |
| **钉住**（点夹子）= 固定在最前面、永不自动删 | ✅ | 钉住后灌 20 条把容量撑爆：最左边那张 `item 6` 仍在原位，其余已刷到 26~32 |
| 钉住的卡片照样能悬停 / 放大 / 点叉号 | ✅ | 日志 `js: pin p13 -> kept=true` 后悬停卡身 `js: hover id=p13 hit=true`（修掉了「点不到、像死了一样」） |
| **满线自动清理（看得见）**：最老那张换到最前面那一格，然后掉下去 | ✅ | 日志 `drop p1 idx=19 rect=125,27`（p1 是第一条内容，被换到可见的第 19 位再掉）；逐帧拍到 `numbered item 23` 脱钩斜着下落 |
| 保留张数 25/50/100、一直显示 会存盘 | ✅ | 写在 `%APPDATA%\liangyijia\settings.txt`，重启保留 |
| 深浅主题跟随系统 | ✅ | 之前写死深色，现在读 `prefers-color-scheme`，系统是浅色卡片就是白的 |
| 只有复制时显示（默认） | ✅ | 启动时线收起；复制内容后滑下来；3.2 秒无交互自动收回（日志 `hide: idle=3202ms`） |
| 指针贴屏幕顶部把线叫出来 | ✅ | 指针移到 y≤234 时线放下；停在那里不动也保持 |
| 一直显示（托盘开关） | ✅ | 托盘勾选后指针移开 5.5 秒线仍在 |
| 点叉号删除卡片 | ✅ | 点击后 `rects` 4→3，卡片消失 |
| 托盘图标 + 菜单（显示/隐藏、退出） | ✅ | 任务栏通知区可见衣架图标 |
| 绳子 / 夹子 / 卡片 / 落位摆动 / 风 | ✅ | 与 macOS 版同一套公式 |
| 文字卡 / 链接卡渲染、深浅主题 | ✅ | |

## 还没做

- **截图文件夹监听**：`Win+PrtSc` 存到「图片\屏幕截图」、`Win+Shift+S` 只进剪贴板，需要盯着多个来源
- **多屏与 DPI 切换**：目前只取主屏；副屏不同缩放还没处理
- **开机自启**：注册表 Run 项或计划任务
- **保留数 / 滚轮回看**：界面层有（`keepOnLine` / `frontScroll`），托盘菜单还没接，滚轮也收不到（窗口不激活）
- **悬停按 Delete 删除**：窗口 `WS_EX_NOACTIVATE`，键盘事件进不来，现在只能点叉号
- **NSIS 安装包**：这台 ARM64 Windows 上跑不出来 —— Tauri 缓存里的 `makensis.exe`（2.5KB 那个）
  是个启动器，起不来（`error 0x2`）；换成真正的 `NSIS\Bin\makensis.exe` 又缺依赖 DLL
  （退出码 `0xC0000135`）。所以现在发的是「免安装 exe + install.cmd」方案（见 `dist/`）。
- **网页标题抓取**：链接卡现在显示域名，不是真实标题
- **钉住状态不持久化**：钉住只在本次运行有效（macOS 版会存）
- **滚轮回看**：窗口不激活收不到 wheel，25/50/100 张里靠左的部分看不到，只能等它被删

## 满线清理的规矩（Windows 和 macOS 不一样）

**Windows：换位掉落，线不动。**

每进来一条新内容、超出保留张数时，把**最老那张换到「屏幕最前面那一格」**，
然后在那儿掉下去。这一格指的是最左边那张 —— **包括已经贴边淡出、快看不见的那张**
（它本来就在往外走，让它掉最自然）；钉住的那几张不算。两件事同时成立：

- 掉下去的确实是**最老的内容**（语义对）；
- 动画演在**眼前**（不用为了看它掉把整条线滑几千像素再滑回来）。

换位是同一帧内完成的，画面上看到的就是「最前面那张掉下去、后面补位、新内容从右边进来」。
钉住的卡片永远不参与，点夹子可以钉住 / 取消钉住。

**macOS：保留原来的「滑到最老一头再滑回」**。那边能滑动回看，把屏幕最前面那张清掉
等于提前扔掉还能翻到的旧内容；Windows 收不到滚轮（窗口不抢焦点），屏幕外的卡片本来
也摸不到，所以才改成换位。

## 构建

需要 Node 18+ / Rust stable / VS Build Tools（C++ + Windows SDK）/ WebView2 运行时（Win11 自带）。

```bash
cd win
npm install
npx tauri icon app-icon.png      # 只在首次或换图标时跑
npx tauri build --no-bundle      # 产物：src-tauri/target/release/liangyijia.exe
```

出安装包（macOS / Windows 各一份，都放在仓库根的 `dist/`）：

```bash
scripts/build-app.sh release      # 编 build/晾衣架.app（默认 arm64 + x86_64）
scripts/make-dmg.sh 1.0.0         # 打成 dist/12-LiangYiJia-1.0.0-universal.dmg
```

Windows 那边是「免安装 exe + `install.cmd`」打包成 zip（NSIS 安装器在这台 ARM64 虚拟机上编不出来，原因见下面「还没做」）。

只想看界面、不编 Rust（在任意系统上）：

```bash
cd win/ui && python3 -m http.server 8765    # 浏览器打开 index.html
```

调试参数（浏览器用）：`?settle=3` 先快进 3 秒摆稳、`?freeze=1` 只画一帧（无头截图必用）、
`?demo=overflow` 复现超限清理、`?debug=1` 显示读数。

环境变量（原生用）：`LIANGYIJIA_DEMO=1` 塞示例卡片、`LIANGYIJIA_DEBUG=1` 输出光标与按键诊断日志到
`%TEMP%\liangyijia.log`。

## 结构

```
win/
├── ui/                     前端（纯 HTML/Canvas，不依赖 Windows）
│   ├── index.html
│   └── src/{app,line,draw,layout,spring,textcard}.js + style.css
└── src-tauri/              Rust 外壳
    ├── src/main.rs         窗口样式、光标轮询、剪贴板、托盘
    ├── tauri.conf.json     透明/置顶/无边框窗口配置
    └── capabilities/       前端权限（只开核心集）
```

## 三个平台限制

0. **点卡片上的三个位置**：夹子（顶端中间）= 钉住 / 取消钉住；左上角叉号 = 删除；卡片其它位置 = 复制回剪贴板。

1. **磨砂玻璃做不到**。macOS 卡片背面能透出并模糊桌面；Windows 只有「整窗模糊」或「不模糊」，
   整窗模糊会把带子空白处也糊成一条毛玻璃横条，更难看。现在用半透明白底 + 上亮下暗描边近似。
2. **点击不能靠 DOM**。窗口带 `WS_EX_NOACTIVATE`，点击不会激活它，WebView2 因此收不到 `click`
   （实测一次都没触发）。所以鼠标左键由 Rust 以 60Hz 轮询 `GetAsyncKeyState`，命中卡片时发
   `card-click` 给前端。轮询间隔不能再放大，否则短促点击会漏采。
3. **窗口尺寸必须按物理像素设**。`tauri.conf.json` 里的 `width/height` 是逻辑点，200% 缩放下
   会被系统再乘一次，窗口比屏幕还宽，右边的卡片直接被推到屏幕外。`main.rs` 里按
   `monitor.size()`（物理像素）重新设了一次。

## 踩过的坑（写在这儿省得下次重踩）

- **`prlctl` 在包装脚本里调 `/bin/ps`**，受限环境下直接 `Operation not permitted`。绕过办法是直接执行
  `/Applications/Parallels Desktop.app/Contents/MacOS/prlctl`（真二进制，不是 `/usr/local/bin` 那个包装脚本）。
- **`prlctl exec` 跑在 Session 0**，那里启动的窗口在桌面上看不见。要真机验收必须用计划任务
  （`LogonType=InteractiveToken`，`schtasks /create /xml`）把程序拉进用户会话。
- **截图与鼠标脚本必须 DPI 感知**。DPI-unaware 进程在 200% 缩放下只截到屏幕左上角四分之一，
  `SetCursorPos` 的坐标也会被再乘一次缩放系数。
- **PowerShell 5.1 按 ANSI 读没有 BOM 的 .ps1**。脚本里写中文会破坏语法（变量名被吃、路径乱码），
  脚本一律纯 ASCII，中文只放在数据里。
- **crates.io 直连很慢**（卡在 `Updating crates.io index` 十几分钟），换 rsproxy 稀疏镜像后几秒完成。
- **正在运行的 exe 无法覆盖**，重建前必须先 `taskkill`，否则 `os error 5`。
- **命中测试必须和绘制顺序一致**。钉住的卡片画在最上层，`hitTest` 却按数组顺序返回第一张命中的，
  结果点在钉住的卡上命中的是它下面那张普通卡 —— 钉住的卡怎么点都没反应（看起来像"死了"）。
  现在先问钉住的、再问普通的。
- **几千像素的滑动不能靠横向弹簧跟**。清理时要滑到最老一头（25 张约 3300px），而卡片横向位置是弹簧
  跟动画的，0.42 秒后弹簧还没追上：实测那一刻卡片还在 `x=-299`（屏幕外），掉落动画等于演给空气看。
  清理期间改成「位置直接跟着滑动动画走」（`scrollTo(..., snap=true)`），滑到哪儿卡片就在哪儿。
- **截图连拍要算好单帧耗时**。`CopyFromScreen` + 存 PNG 在虚拟机里一张要 0.3~1 秒，别看代码里写
  `Start-Sleep 70ms` 就以为拍到了；把区域收小、改存 JPEG、并在每帧记一次耗时，才知道有没有覆盖到动画。

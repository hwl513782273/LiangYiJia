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
| 只有复制时显示（默认） | ✅ | 启动时线收起；复制内容后滑下来；3.2 秒无交互自动收回（日志 `hide: idle=3202ms`） |
| 指针贴屏幕顶部把线叫出来 | ✅ | 指针移到 y≤234 时线放下；停在那里不动也保持 |
| 一直显示（托盘开关） | ✅ | 托盘勾选后指针移开 5.5 秒线仍在 |
| 点叉号删除卡片 | ✅ | 点击后 `rects` 4→3，卡片消失 |
| 托盘图标 + 菜单（显示/隐藏、退出） | ✅ | 任务栏通知区可见衣架图标 |
| 绳子 / 夹子 / 卡片 / 落位摆动 / 风 | ✅ | 与 macOS 版同一套公式 |
| 超限清理：滚到最老 → 照原样掉 → 立刻补位 → 滚回 | ✅ | 浏览器端已逐帧验收 |
| 文字卡 / 链接卡渲染、深浅主题 | ✅ | |

## 还没做

- **截图文件夹监听**：`Win+PrtSc` 存到「图片\屏幕截图」、`Win+Shift+S` 只进剪贴板，需要盯着多个来源
- **多屏与 DPI 切换**：目前只取主屏；副屏不同缩放还没处理
- **开机自启**：注册表 Run 项或计划任务
- **保留数 / 滚轮回看**：界面层有（`keepOnLine` / `frontScroll`），托盘菜单还没接，滚轮也收不到（窗口不激活）
- **悬停按 Delete 删除**：窗口 `WS_EX_NOACTIVATE`，键盘事件进不来，现在只能点叉号
- **安装包**：`tauri build` 出 NSIS 安装器还没跑通验收
- **网页标题抓取**：链接卡现在显示域名，不是真实标题
- **「一直显示」不持久化**：重启回到默认（只有复制时显示）

## 构建

需要 Node 18+ / Rust stable / VS Build Tools（C++ + Windows SDK）/ WebView2 运行时（Win11 自带）。

```bash
cd win
npm install
npx tauri icon app-icon.png      # 只在首次或换图标时跑
npx tauri build --no-bundle      # 产物：src-tauri/target/release/liangyijia.exe
```

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

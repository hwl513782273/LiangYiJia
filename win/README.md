# 晾衣架 · Windows 版

macOS 版的 Windows 重写。**目前只完成了界面层（原型），还不能当成品用。**

技术路线选的是 **Tauri**（Rust 外壳 + 网页界面）：安装包几 MB、以后能顺带出 Linux、
剪贴板/热键/托盘都有官方插件。界面用 HTML Canvas 逐帧自绘，物理参数照抄 macOS 版。

---

## 现在能做什么

| 能力 | 状态 |
|---|---|
| 绳子（抛物线、三段叠画、两端渐隐） | ✅ 与 macOS 版同一套公式 |
| 夹子（金属渐变、深空灰表示钉住） | ✅ |
| 卡片（玻璃边框、投影、悬停放大） | ✅ |
| 新卡片落位摆动（弹簧） | ✅ |
| 每 7~16 秒一阵风，全部卡片轻推 | ✅ |
| 悬停出删除按钮 / 按 Delete 删除 | ✅ |
| 超限清理：滚到最老一头 → 照原样掉 → 立刻补位 → 滚回 | ✅ 见下方调试参数 |
| 文字卡 / 链接卡（按主题渲染成图片再挂） | ✅ |
| 收起 / 放下（整条线滑到屏幕外） | ✅ |
| 深浅主题 | ✅ |

## 还不能做什么

这些是 **Windows 版真正的工作量所在**，目前一行都没写：

- **Tauri 外壳**：透明置顶窗、不抢焦点、逐像素点击穿透
- **剪贴板监听**（Windows 的 `AddClipboardFormatListener`）
- **截图目录监听**（Windows 没有统一落点：`Win+PrtSc` 进 `图片\屏幕截图`，
  `Win+Shift+S` 只进剪贴板，第三方工具各有各的目录）
- **托盘菜单**、**全局热键**（`RegisterHotKey`）、**开机自启**（注册表 Run）
- **多屏定位 + Per-Monitor V2 DPI**（Windows 每块屏缩放比可能不同）
- **磁盘持久化**（macOS 版存 UserDefaults + 记录文件）
- **全屏应用检测**（Windows 没有对应系统事件，要自己比对前台窗口矩形）

---

## 怎么跑

只跑界面原型，任何系统都行：

```bash
cd win
python3 -m http.server 8765
# 打开 http://127.0.0.1:8765/index.html
```

### 调试参数

| 参数 | 作用 |
|---|---|
| `?settle=3` | 先把模拟快进 3 秒再画第一帧（截稳定态用） |
| `?freeze=1` | 只画一帧就停住。**无头截图必须加**，否则浏览器会继续跑几十帧，拍到的是动画结束后的样子 |
| `?debug=1` | 显示运行时读数（items / flights / 掉落卡片坐标 / alpha） |
| `?demo=overflow` | 挂满一屏再加一张，复现"超限清理"整段动画 |

三个参数可以叠加，例如抓清理动画的第 0.55 秒：

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
  --window-size=1440,900 --virtual-time-budget=1200 \
  --screenshot=/tmp/scan.png \
  "http://127.0.0.1:8765/index.html?demo=overflow&settle=0.55&freeze=1&debug=1"
```

---

## 目录

```
win/
├── index.html          假桌面 + 工具栏（套进 Tauri 后这两层都不存在）
└── src/
    ├── layout.js       版式与几何：全部照抄 LineView.swift 的 Layout
    ├── spring.js       弹簧数值积分（SwiftUI 的 .spring 在网页里没有对应物）
    ├── line.js         线本身：挂载、滚动、超限清理、风
    ├── draw.js         逐帧绘制：绳子 / 夹子 / 卡片 / 掉落
    ├── textcard.js     文字卡与链接卡（先渲染成图片再挂，与 macOS 版同思路）
    └── app.js          入口：画布、循环、鼠标、键盘、调试参数
```

## 与 macOS 版的对应关系

| macOS | Windows 原型 |
|---|---|
| `LineView.swift` 的 `Layout` | `layout.js`（逐项对照，含 `sag()`、`x()`、`frontScroll()`） |
| `Line.swift` | `line.js` |
| `LineView.swift` / `PeggedView.swift` 的绘制 | `draw.js` |
| `CardRenderer.swift` | `textcard.js` |
| SwiftUI `.spring()` / `.interpolatingSpring()` | `spring.js`（自己积分） |

参数对照（改任何一边都要同步另一边）：

- `photoMaxHeight = 104`、`cardWidth = 150`、`spacing = cardWidth + 24`、`panelHeight = photoMaxHeight + 106`
- `ropeTop = 10`、`pinAbove = 9.5`、`sag = min(30, width * 0.018)`
- 落位摆动：`interpolatingSpring(stiffness: 46, damping: 2.6)`，起始 16°
- 位置补间：`spring(response: 0.55, dampingFraction: 0.78)`
- 卡片圆角 16、照片内缩 4

## 已知差异（不是 bug，是平台限制）

1. **磨砂玻璃做不到**。macOS 用 `.ultraThinMaterial` 让卡片背面透出并模糊桌面；
   Windows 只有"整窗模糊"或"完全不模糊"，整窗模糊会把带子的空白处也糊掉，
   屏幕上会出现一条毛玻璃横条，更难看。这里用半透明白底 + 上亮下暗的细描边近似。
2. **掉落动画需要额外的窗口高度**。macOS 是另开一个全屏窗口画掉落（`CaptureFlight.swift`），
   这里暂时把窗口本身做高（`stageHeight()`），卡片掉出舞台再淡掉。接 Tauri 后
   应该改成和 macOS 一样的临时全屏覆盖窗。
3. **"空位保留"没做**。macOS 版指针停在线上时，掉落的卡片会先留个空位，
   连续删多张时叉号不会乱跑。这里掉落即摘除。

## 验证边界（重要）

界面层是在 **macOS 的 Chrome** 里验证的：无头浏览器按 `?settle` 快进到指定时刻截图，
逐帧核对过落位摆动、超限清理四个阶段、掉落回收。

**没有在 Windows 上跑过。** 这台机器上虽然有 Parallels 的 Windows 11 虚拟机，
但命令行控制它需要 `prlctl`，而 `prlctl` 内部调用 `/bin/ps` 在这个环境里被系统拒绝
（`Operation not permitted`，关沙箱也一样），所以没法启动虚拟机、也没法往里执行命令。

Windows 上还没验证的：中文字体渲染、DPI 缩放下的清晰度、Edge WebView2 的透明底质量。

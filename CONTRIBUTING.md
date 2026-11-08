# 参与开发 / Contributing

晾衣架是 Tendedero 的中文改版（MIT）。改版只做「让它更顺手」这一件事，所以规则很简单：一个改动解决一个具体问题，不把界面变复杂。

LiangYiJia is a Chinese fork of Tendedero (MIT). The fork exists for one reason — making the line easier to live with — so the rule is simple: one change, one concrete problem, and never a busier interface.

## 提交前 / Before you start

- 大改动先开 issue 说明「现在什么场景不好用、你想怎么改」。小修、翻译、错字可以直接发 PR。
  Open an issue first for anything bigger than a fix, describing the scenario that hurts and what you want to change. Small fixes, translations and typos can go straight to a PR.
- 一个 PR 只做一件事；不要在修 bug 的同时重排文件。
  One PR, one thing. Do not reformat half the project while fixing a bug.

## 构建与自测 / Build and test

需要 macOS 14+ 与 Swift 5.9 工具链。构建产物在 `build/` 下，**不要提交 `build/`、`.app`、`dmg`**。

Requires macOS 14+ and the Swift 5.9 toolchain. Output lands in `build/`; **never commit `build/`, `.app` or `dmg`**.

```
bash scripts/build-app.sh release
open "build/晾衣架.app"
```

手工过一遍这几条再发 PR（这几处最容易改坏）：

Walk through these by hand before opening a PR — they are the easiest to break:

1. 截图一次 → 卡片挂上；指针移开 → 绳子收起。
   Take a screenshot → the card hangs; move the pointer away → the line retracts.
2. 复制一段文字、一个网址、一张图片 → 各挂一张；点回去 → 剪贴板恢复原文。
   Copy text, a URL and an image → one card each; click a card → the clipboard gets the original back.
3. 把保留上限调到 25，连续复制 30 条 → 文件夹里精确剩 25 个，超限那张有掉落动画。
   Set retention to 25, copy 30 items → exactly 25 files remain and the overflow card drops with its animation.
4. 鼠标停在卡片上按 Delete → 只删这张；移开再按 → 恢复成普通删除键。
   Hover a card and press Delete → only that card goes; move away and press again → the key behaves normally.
5. 勾上「一直显示」→ 指针移开绳子不收；线上空了绳子仍在。
   Tick "一直显示" → the line stays after the pointer leaves, even when empty.

## 语言与文案 / Strings

界面文字一律走 `L()` → `NSLocalizedString`，不要硬编码。新增文案要同时补 `Sources/Tendedero/Resources/en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings`，**两张表必须一一对齐、不能缺条**。

Every user-facing string goes through `L()` → `NSLocalizedString`. New strings must be added to **both** `en.lproj` and `zh-Hans.lproj` under `Sources/Tendedero/Resources/`, kept in sync with no missing keys.

## 代码风格 / Style

- 沿用现有写法：能在原文件里加就加，不为了「更整齐」新建一层抽象。
  Follow what is there. Add to the existing file instead of inventing a layer of abstraction.
- 每处「为什么不那样写」的坑，在代码注释里写清楚原因，别只写「做了什么」。
  When a decision avoids a trap, say *why* in the comment, not just what the code does.
- 不引入第三方依赖。这个项目的一个卖点就是零依赖。
  No third-party dependencies. Zero dependencies is part of the point.

## 许可 / License

提交的代码按 [MIT](LICENSE) 授权。请勿把 Tendedero 的名称或图标带进本仓库。
Contributions are licensed under [MIT](LICENSE). Do not bring the Tendedero name or icon into this repository.

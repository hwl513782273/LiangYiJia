// 入口：把模型、绘制、输入接起来，跑成 60 帧的循环。
// 这个文件在浏览器里能直接跑（先在 Mac 上看效果），之后套进 Tauri 壳时不用改。
//
// 调用时机：index.html 加载完就执行一次。

import { Line, Item } from './line.js';
import { render, hitTest } from './draw.js';
import { makeTextCard, makeLinkCard } from './textcard.js';
import { clamp } from './layout.js';

const canvas = document.getElementById('line');
const ctx = canvas.getContext('2d');

const line = new Line();

// 主题跟随系统（macOS 版也是跟系统外观走）。
// 之前这里写死 true，所以不管系统是深是浅，卡片永远是黑的。
const darkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
let dark = darkQuery ? darkQuery.matches : false;
let hoverId = null;
let reveal = 1;          // 1 = 放下，0 = 收起
let revealTarget = 1;

// 「只有复制的时候显示」/「一直显示」—— 对应 macOS 版菜单里的同一个开关。
// 默认后者关闭：内容来了滑下来，几秒没人理就收回去；指针移到屏幕顶部也能叫出来。
// 托盘菜单里打开「一直显示」后，这条线就常驻不收。
let alwaysShown = false;
let lastActive = performance.now();
let lastCursor = { x: -1, y: -1 };   // 最后一次已知的指针位置（窗口内 CSS 坐标）
const HIDE_AFTER = 3200;   // 毫秒：最后一次交互后多久收回

/** 把线放下来，并重置「多久没理我」的计时。 */
function showLine() {
  revealTarget = 1;
  lastActive = performance.now();
}

const params = new URLSearchParams(location.search);

// 原生模式：页面跑在 Tauri 里（有 __TAURI__）时，去掉假桌面和工具栏、背景透明，
// 并告诉外壳「现在可以整窗点击穿透」。
// 浏览器里跑（原型预览）时这些都不做，方便在 Mac 上直接看效果。
const isNative = typeof window.__TAURI__ !== 'undefined';
if (isNative) document.documentElement.classList.add('native');
const tauriInvoke = isNative ? window.__TAURI__.core.invoke : async () => {};

// 原生 + 示例内容一起开时，顺便在屏幕上显示一行读数。
// 用途：Windows 上没法开 DevTools，只能把 innerWidth/dpr/可见张数直接画出来核对版式。
let nativeDebug = false;
let clickCount = 0;

// ---------- 视口与缩放 ----------
// 高分屏上按 devicePixelRatio 放大画布，再整体缩放，线才不会糊。
let dpr = 1;

// 舞台高度：线本身只占顶上 panelHeight（约 210），但掉落的卡片要往下坠一段才好看。
// macOS 版是另开一个全屏窗口画掉落（CaptureFlight.swift），
// Windows 这边先让窗口本身高一些，卡片掉出舞台再淡掉。
function stageHeight() {
  return Math.min(window.innerHeight, 640);
}

function resize() {
  dpr = window.devicePixelRatio || 1;
  const w = window.innerWidth;
  const h = stageHeight();
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
  canvas.style.width = `${w}px`;
  canvas.style.height = `${h}px`;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  line.resize(w);
}
// 改画布尺寸会清空内容，必须立刻重画。
// 带 rAF 时下一帧自然会补上；?freeze=1 没有下一帧，不重画就是一张空白图
//（无头浏览器加载完后还会触发一次 resize，踩过）。
window.addEventListener('resize', () => {
  resize();
  drawFrame();
});

// ---------- 假截图 ----------
// 原型阶段没有真的截图，先画几张假窗口出来，方便看清卡片和绳子的关系。
function makeFakeShot({ w = 640, h = 400, accent = '#3B82F6', bars = true }) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const g = c.getContext('2d');

  g.fillStyle = '#F7F8FA';
  g.fillRect(0, 0, w, h);

  // 顶栏 + 三个红绿灯
  g.fillStyle = '#E8EAEF';
  g.fillRect(0, 0, w, 34);
  const dots = ['#FF5F57', '#FEBC2E', '#28C840'];
  dots.forEach((col, i) => {
    g.beginPath();
    g.arc(18 + i * 18, 17, 5.5, 0, Math.PI * 2);
    g.fillStyle = col;
    g.fill();
  });

  // 一句标题占位
  g.fillStyle = '#C9CDD6';
  g.fillRect(84, 12, Math.min(180, w * 0.3), 10);

  // 内容块
  if (bars) {
    const px = 28, py = 62;
    g.fillStyle = accent;
    g.globalAlpha = 0.85;
    g.fillRect(px, py, Math.min(220, w * 0.4), 86);
    g.globalAlpha = 1;
    for (let i = 0; i < 4; i++) {
      g.fillStyle = '#DDE1E8';
      g.fillRect(px + Math.min(220, w * 0.4) + 24, py + i * 24, (w - px * 2 - Math.min(220, w * 0.4) - 24) * (i === 3 ? 0.5 : 0.9), 12);
    }
    // 下面几行"正文"
    for (let i = 0; i < 5; i++) {
      g.fillStyle = i % 2 ? '#E7EAF0' : '#DDE1E8';
      g.fillRect(px, 180 + i * 26, (w - px * 2) * (0.95 - i * 0.08), 11);
    }
  }

  return c;
}

// ---------- 演示内容 ----------
function addShot(opts) {
  const img = makeFakeShot(opts);
  line.hang(new Item({ kind: 'image', image: img, source: '截图' }));
}

function addText() {
  const text = '今天这套方案的核心是：把「复制过什么」变成一个看得见的东西。不再是一份列表，而是挂在屏幕顶上的一根线上——截个图、复制一段话，它就掉上去晃两下。';
  const img = makeTextCard({ text, source: '剪贴板', dark });
  line.hang(new Item({ kind: 'text', image: img, text, source: '剪贴板' }));
}

function addLink() {
  const url = 'https://github.com/hwl513782273/LiangYiJia';
  const title = '晾衣架 - 截图/文字/链接/图片全挂到屏幕顶上的一根线上';
  const img = makeLinkCard({ url, title, source: '剪贴板', dark });
  line.hang(new Item({ kind: 'link', image: img, url, title, source: '剪贴板' }));
}

function seed() {
  addShot({ w: 720, h: 450, accent: '#3B82F6' });
  addText();
  addLink();
  addShot({ w: 420, h: 640, accent: '#8B5CF6' });
}

// ---------- 每帧 ----------
let last = performance.now();

/** 只画一帧，不推进时间。 */
function drawFrame() {
  render(ctx, line, { width: window.innerWidth, height: stageHeight(), dark, hoverId, reveal });

  // 画完 rects 才是这一帧的真实位置，这时候上报给 Rust 做命中判断
  reportHitRects();

  const dbg = document.getElementById('debug');
  if (dbg && (params.get('debug') === '1' || nativeDebug)) {
    const rects = line.items.map((it) => `${it.px.value.toFixed(0)}`).join(',');
    const r0 = line.rects.get(line.items[0] && line.items[0].id);
    dbg.textContent = `w=${window.innerWidth} h=${window.innerHeight} dpr=${(window.devicePixelRatio || 1).toFixed(2)}`
      + ` screen=${window.screen.width}x${window.screen.height}\n`
      + `canvas=${canvas.width}x${canvas.height} css=${canvas.clientWidth}x${canvas.clientHeight}`
      + ` line=${line.width} visible=${line.visibleCount} items=${line.items.length}\n`
      + `cardW=${line.layout.cardWidth} spacing=${line.layout.spacing} hover=${hoverId ?? '-'} clicks=${clickCount} centers=${rects}`
      + (r0 ? `\nrect0=(${r0.x.toFixed(0)},${r0.y.toFixed(0)}) ${r0.w.toFixed(0)}x${r0.h.toFixed(0)}` : '');
  }
}

function frame(now) {
  const dt = Math.min((now - last) / 1000, 0.1);
  last = now;

  line.tick(dt);

  // 指针停在热区里就一直放着（事件只在移动时来，所以每帧看一次记住的位置）
  if (lastCursor.y >= 0 && lastCursor.y <= line.layout.panelHeight + 24) showLine();

  // 只有复制时显示：hover 或最近有过交互就不收
  if (!alwaysShown && revealTarget === 1 && hoverId == null && performance.now() - lastActive > HIDE_AFTER) {
    revealTarget = 0;
    if (isNative) tauriInvoke('js_log', { msg: `hide: idle=${Math.round(performance.now() - lastActive)}ms` }).catch(() => {});
  }

  // 收起/放下做个简单的补间
  if (reveal !== revealTarget) {
    const step = dt / 0.32;
    reveal = revealTarget > reveal ? Math.min(revealTarget, reveal + step) : Math.max(revealTarget, reveal - step);
  }

  drawFrame();
  requestAnimationFrame(frame);
}

// ---------- 鼠标 ----------
// 浏览器原型直接听 mousemove；原生模式下窗口大部分时间是点击穿透的，
// 收不到 mousemove，改由 Rust 侧轮询系统光标后通过 'cursor' 事件送坐标过来。
/**
 * 应用「保留张数」。
 * 0 = 一屏能放几张就几张；25/50/100 = 保留这么多，再多就把最老的自动删掉。
 * 调用时机：启动时读一次设置、托盘里改保留数、窗口尺寸变化。
 */
function applyKeep(n) {
  line.keepOnLine = n > 0 ? n : null;
  line.resize(window.innerWidth);   // 重算 maxItems
  // 调小保留数时，多出来的要按满线的规矩下线（否则数字改了线却没变）
  line.trim();
  showLine();
}

/**
 * 悬停预览图按需生成，生成一次就缓存。
 * 依据是卡片自己的内容：文字卡/链接卡重画一张「展开版」，图片卡直接用原图。
 */
function ensurePreview(it) {
  if (it.preview) return;
  if (it.kind === 'text' && it.text) {
    it.preview = { img: makeTextCard({ text: it.text, source: it.source, dark, expanded: true }), scale: 2 };
  } else if (it.kind === 'link' && it.url) {
    it.preview = { img: makeLinkCard({ url: it.url, title: it.title, source: it.source, dark, expanded: true }), scale: 2 };
  } else if (it.image) {
    it.preview = { img: it.image, scale: 1 };
  }
}

/**
 * 把卡片原文写回系统剪贴板。
 * macOS 版点卡片就是「复制回原文」，Windows 这边之前只画了个角标，实际没写，
 * 现在补上：文字卡写文字，链接卡写网址；图片卡暂不处理。
 */
function copyItemToClipboard(it) {
  const text = it.text || it.url;
  if (!text) return;
  if (isNative) tauriInvoke('copy_text', { text }).catch(() => {});
  else if (navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
}

function applyHover(mx, my) {
  const hit = hitTest(line, mx, my);
  const id = hit ? hit.id : null;
  if (id !== hoverId) {
    hoverId = id;
    for (const it of line.items) {
      it.hoverScale.target = it.id === id ? 1.035 : 1;
    }
    if (isNative) {
      tauriInvoke('js_log', { msg: `hover id=${id} hit=${!!hit} kind=${hit && hit.kind}` }).catch(() => {});
    }
    if (hit) {
      // 预览生成失败不该连带把悬停也搞坏，单独兜住
      try {
        ensurePreview(hit);
        if (isNative) tauriInvoke('js_log', { msg: `preview ok=${!!hit.preview}` }).catch(() => {});
      } catch (err) {
        if (isNative) tauriInvoke('js_log', { msg: 'preview fail: ' + err }).catch(() => {});
      }
      showLine();
    }
  }
  canvas.style.cursor = id ? 'pointer' : 'default';
}

canvas.addEventListener('mousemove', (e) => {
  const r = canvas.getBoundingClientRect();
  applyHover(e.clientX - r.left, e.clientY - r.top);
});

canvas.addEventListener('mouseleave', () => {
  hoverId = null;
  for (const it of line.items) it.hoverScale.target = 1;
  line.closeGaps();
});

/**
 * 处理一次点击：左上角 26×26 是删除按钮，其余位置点一下=复制原文。
 * 两个来源共用这一份逻辑 —— 浏览器里走 DOM click，原生里走 Rust 发来的 card-click。
 */
function handleClick(mx, my) {
  clickCount += 1;

  // ① 先判夹子：夹子画在卡片矩形上方，hitTest 够不到，得单独找。
  // 点夹子 = 钉住 / 取消钉住。钉住的卡片永远排在线的最前面，自动清理也不会碰它。
  const pegHit = line.items.find((it) => {
    const r = line.rects.get(it.id);
    if (!r) return false;
    const cx = r.x + r.w / 2;
    return Math.abs(mx - cx) <= 16 && my <= r.y + 8 && my >= r.y - 26;
  });
  if (isNative) {
    const r0 = pegHit ? line.rects.get(pegHit.id) : null;
    tauriInvoke('js_log', { msg: `click ${mx.toFixed(0)},${my.toFixed(0)} peg=${pegHit ? pegHit.id : 'none'} rect=${r0 ? Math.round(r0.x) + ',' + Math.round(r0.y) : '-'} items=${line.items.length}` }).catch(() => {});
  }
  if (pegHit) {
    try {
      const kept = line.toggleKept(pegHit.id);
      if (isNative) tauriInvoke('js_log', { msg: `pin ${pegHit.id} -> kept=${kept} keptCount=${line.keptCount}` }).catch(() => {});
      if (kept != null) showLine();
    } catch (err) {
      if (isNative) tauriInvoke('js_log', { msg: 'pin fail: ' + err }).catch(() => {});
    }
    return;
  }

  const hit = hitTest(line, mx, my);
  if (!hit) return;
  const rect = line.rects.get(hit.id);

  // ② 左上角 26×26 = 删除
  if (rect && mx < rect.x + 26 && my < rect.y + 26) {
    line.drop(hit.id);
    return;
  }

  // ③ 其它位置 = 复制回剪贴板
  line.copy(hit.id);
  copyItemToClipboard(hit);
}

canvas.addEventListener('click', (e) => {
  // 原生模式下不处理 DOM click：Rust 侧轮询左键已经发过 card-click，
  // 两边都处理会让同一次点击跑两遍（钉住会立刻被自己取消，实测踩过）。
  if (isNative) return;
  const r = canvas.getBoundingClientRect();
  handleClick(e.clientX - r.left, e.clientY - r.top);
});

// 滚轮：只有在"保留数大于一屏"时才有前后可翻
canvas.addEventListener('wheel', (e) => {
  if (line.keepOnLine == null || line.items.length <= line.visibleCount) return;
  e.preventDefault();
  const limit = line.layout.frontScroll(line.items.length, line.visibleCount);
  line.scrollTween = null;
  line.scroll = clamp(line.scroll + e.deltaY * 0.6, 0, limit);
}, { passive: false });

// Delete 删除悬停的那张（对应 macOS 版悬停时注册的 Carbon 热键）
window.addEventListener('keydown', (e) => {
  if ((e.key === 'Delete' || e.key === 'Backspace') && hoverId) {
    e.preventDefault();
    line.drop(hoverId);
    hoverId = null;
  }
});

// ---------- 上报卡片矩形 ----------
// Rust 侧靠这份矩形判断「指针是否压在卡片上」，从而临时取消整窗穿透。
// 只在矩形真的变了才发，避免每帧都走一次 IPC。
let lastRectsKey = '';
function reportHitRects() {
  if (!isNative) return;
  const arr = [];
  for (const it of line.items) {
    const r = line.rects.get(it.id);
    if (!r) continue;
    // 往上多算 22：夹子画在卡片上方，点夹子也要算「在卡片上」，
    // 否则那一刻窗口是穿透的，点击直接落到桌面上（实测过）。
    arr.push([r.x, r.y - 22, r.w, r.h + 22]);
  }
  const key = arr.map((a) => a.map((v) => Math.round(v)).join(',')).join(';');
  if (key === lastRectsKey) return;
  lastRectsKey = key;
  tauriInvoke('set_hit_rects', { rects: arr }).catch(() => {});
}

// ---------- 原生事件：剪贴板 ----------
function looksLikeUrl(s) {
  const t = String(s).trim();
  return !t.includes('\n') && t.length < 2048 && (t.startsWith('http://') || t.startsWith('https://'));
}

function addClipText(text) {
  if (looksLikeUrl(text)) {
    const url = String(text).trim();
    let title = url;
    try { title = new URL(url).host || url; } catch { /* 不是合法 URL 就原样显示 */ }
    const img = makeLinkCard({ url, title, source: '剪贴板', dark });
    line.hang(new Item({ kind: 'link', image: img, url, title, source: '剪贴板' }));
  } else {
    const img = makeTextCard({ text, source: '剪贴板', dark });
    line.hang(new Item({ kind: 'text', image: img, text, source: '剪贴板' }));
  }
}

function addClipImage(dataUrl) {
  const img = new Image();
  img.onload = () => line.hang(new Item({ kind: 'image', image: img, source: '剪贴板' }));
  img.src = dataUrl;
}

if (isNative) {
  const { listen } = window.__TAURI__.event;
  // 指针位置（窗口穿透时前端收不到 mousemove，只能靠系统光标轮询）
  let cursorSeen = false;
  listen('cursor', (e) => {
    const [x, y] = e.payload;
    if (!cursorSeen) {
      cursorSeen = true;
      tauriInvoke('js_log', { msg: `first cursor ${x.toFixed(0)},${y.toFixed(0)}` }).catch(() => {});
    }
    lastCursor = { x, y };
    // 指针贴到屏幕顶部就把线叫出来（macOS 版的 hot zone 同一套逻辑）
    if (y <= line.layout.panelHeight + 24) showLine();
    applyHover(x, y);
  }).catch((err) => tauriInvoke('js_log', { msg: 'listen cursor failed: ' + err }));

  // 告诉原生侧监听已就绪，剪贴板内容从现在开始投递
  tauriInvoke('frontend_ready').catch(() => {});

  // 托盘菜单里的「保留张数」
  listen('keep-changed', (e) => applyKeep(Number(e.payload) || 0));

  // 托盘菜单里的「一直显示」：状态存在 Rust 侧，切换后通知这边
  listen('always-changed', (e) => {
    alwaysShown = !!e.payload;
    if (alwaysShown) showLine();
    else lastActive = 0;
  });

  // 右键点卡片 = 钉住 / 取消钉住（对应 macOS 版的右键菜单）。
  // 钉住的卡片固定在线的最前面，永远不会被自动清理掉。
  listen('card-right-click', (e) => {
    const [x, y] = e.payload;
    const hit = hitTest(line, x, y);
    if (!hit) return;
    const kept = line.toggleKept(hit.id);
    if (kept != null) showLine();
  });

  // 点击由 Rust 轮询鼠标左键后发来：窗口不激活，DOM 的 click 收不到。
  listen('card-click', (e) => {
    const [x, y] = e.payload;
    handleClick(x, y);
  });
  // 剪贴板新内容
  listen('clip', (e) => {
    showLine();
    const p = e.payload || {};
    if (p.kind === 'text') addClipText(p.text);
    else if (p.kind === 'link') addClipText(p.url);
    else if (p.kind === 'image') addClipImage(p.data);
  });
}

// 系统外观变了就重画文字卡/链接卡（它们是预先渲染成图片的，不重画不会变色）
if (darkQuery) {
  darkQuery.addEventListener('change', (e) => {
    dark = e.matches;
    for (const it of line.items) {
      if (it.kind === 'text') {
        it.image = makeTextCard({ text: it.text, source: it.source, dark });
        it.preview = null;
      }
      if (it.kind === 'link') {
        it.image = makeLinkCard({ url: it.url, title: it.title, source: it.source, dark });
        it.preview = null;
      }
    }
  });
}

// ---------- 工具栏 ----------
function btn(id, fn) {
  document.getElementById(id)?.addEventListener('click', fn);
}

btn('add-shot', () => addShot({ w: 640, h: 400, accent: '#3B82F6' }));
btn('add-text', addText);
btn('add-link', addLink);
btn('toggle-theme', () => {
  dark = !dark;
  document.body.classList.toggle('light', !dark);
  // 文字卡是按主题渲染成图片的，换主题要重画已有的
  for (const it of line.items) {
    if (it.kind === 'text') it.image = makeTextCard({ text: it.text, source: it.source, dark });
    if (it.kind === 'link') it.image = makeLinkCard({ url: it.url, title: it.title, source: it.source, dark });
  }
});
btn('toggle-reveal', () => {
  revealTarget = revealTarget > 0.5 ? 0 : 1;
  document.getElementById('toggle-reveal').textContent = revealTarget > 0.5 ? '收起' : '放下';
});
btn('clear', () => {
  for (const it of [...line.items]) line.drop(it.id);
});

// ---------- 启动 ----------
resize();

// 原生模式下线上应该是空的（真实内容由剪贴板/截图监听挂上来）；
// 但带 LIANGYIJIA_DEMO=1 启动时会塞示例卡片，方便开发期截图验收。
// 浏览器原型则总是塞假数据看效果。
const nativeDemo = isNative ? await tauriInvoke('demo_mode').catch(() => false) : false;
if (!isNative || nativeDemo) seed();

nativeDebug = nativeDemo;
if (nativeDebug) document.documentElement.classList.add('debugon');

// 调试用：?demo=overflow 复现"超限清理"那一段动画。
// 做法是清空、挂满一屏、等它们站稳，再加最后一张去触发一次掉落 ——
// 一次只掉一张，才看得清"滚到最老一头 → 照原样掉 → 立刻补位 → 滚回来"。
if (params.get('demo') === 'overflow') {
  for (const it of [...line.items]) line.drop(it.id);
  line.flights = [];
  line.advance(0.8);
  for (let i = 0; i < line.maxItems; i++) {
    addShot({ w: 640, h: 400, accent: i % 2 ? '#8B5CF6' : '#3B82F6' });
  }
  line.advance(0.8);
  addShot({ w: 720, h: 450, accent: '#F59E0B' });
}

// 调试用：?settle=3 表示先把模拟快进 3 秒再画第一帧。
// 无头浏览器截图必须用它，否则拍到的永远是"刚挂上还没站稳"的瞬间。
const settle = Number(params.get('settle') || 0);
if (settle > 0) line.advance(settle);

// 原生模式：读一次「一直显示」状态决定初始是否放下线。
// 默认关闭 = 只有复制的时候才显示，启动时线是收着的（和 macOS 版一致）。
if (isNative) {
  // 保留张数：读到就用上（必须在 resize 之后再设，否则 maxItems 会被重算覆盖）
  applyKeep(await tauriInvoke('keep_mode').catch(() => 0));
  alwaysShown = await tauriInvoke('always_mode').catch(() => false);
  tauriInvoke('js_log', { msg: `boot always=${alwaysShown}` }).catch(() => {});
  if (alwaysShown) {
    reveal = 1;
    revealTarget = 1;
  } else {
    reveal = 0;
    revealTarget = 0;
  }
}

// 原生模式：窗口默认整窗点击穿透，不挡住桌面和下面程序的点击。
// 等第二阶段接上「指针是否在某张卡上」的轮询后，再按需临时取消穿透。
if (isNative) tauriInvoke('set_click_through', { through: true });

// ?freeze=1 只画一帧就停住：无头截图必须用它，否则浏览器会继续跑几十帧，
// 拍到的是动画结束之后的样子（掉落卡片早就回收了）。也用来做视觉回归基准图。
if (params.get('freeze') === '1') {
  drawFrame();
} else {
  requestAnimationFrame(frame);
}

// 暴露给控制台，方便调试
window.__line = line;

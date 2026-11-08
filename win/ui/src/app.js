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
let dark = true;
let hoverId = null;
let reveal = 1;          // 1 = 放下，0 = 收起
let revealTarget = 1;

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
function applyHover(mx, my) {
  const hit = hitTest(line, mx, my);
  const id = hit ? hit.id : null;
  if (id !== hoverId) {
    hoverId = id;
    for (const it of line.items) {
      it.hoverScale.target = it.id === id ? 1.035 : 1;
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
  const hit = hitTest(line, mx, my);
  if (!hit) return;
  const rect = line.rects.get(hit.id);
  if (rect && mx < rect.x + 26 && my < rect.y + 26) {
    line.drop(hit.id);
  } else {
    line.copy(hit.id);
  }
}

canvas.addEventListener('click', (e) => {
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
    if (r) arr.push([r.x, r.y, r.w, r.h]);
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
    applyHover(x, y);
  }).catch((err) => tauriInvoke('js_log', { msg: 'listen cursor failed: ' + err }));

  // 点击由 Rust 轮询鼠标左键后发来：窗口不激活，DOM 的 click 收不到。
  listen('card-click', (e) => {
    const [x, y] = e.payload;
    handleClick(x, y);
  });
  // 剪贴板新内容
  listen('clip', (e) => {
    const p = e.payload || {};
    if (p.kind === 'text') addClipText(p.text);
    else if (p.kind === 'link') addClipText(p.url);
    else if (p.kind === 'image') addClipImage(p.data);
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

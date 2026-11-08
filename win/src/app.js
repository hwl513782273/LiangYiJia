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

  const dbg = document.getElementById('debug');
  if (dbg && params.get('debug') === '1') {
    const f = line.flights[0];
    dbg.textContent = `items=${line.items.length} flights=${line.flights.length} visible=${line.visibleCount} max=${line.maxItems} reveal=${reveal.toFixed(2)}\n`
      + (f ? `flight y=${f.y.toFixed(0)} alpha=${f.alpha.toFixed(2)} x=${f.x.toFixed(0)} w=${f.w.toFixed(0)}` : 'flight 无');
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
  // ?freeze=1 只画一帧就停住：无头截图必须用它，否则浏览器会继续跑几十帧，
// 拍到的是动画结束之后的样子（掉落卡片早就回收了）。也用来做视觉回归基准图。
if (params.get('freeze') === '1') {
  drawFrame();
} else {
  requestAnimationFrame(frame);
}
}

// ---------- 鼠标 ----------
canvas.addEventListener('mousemove', (e) => {
  const r = canvas.getBoundingClientRect();
  const hit = hitTest(line, e.clientX - r.left, e.clientY - r.top);
  const id = hit ? hit.id : null;
  if (id !== hoverId) {
    hoverId = id;
    for (const it of line.items) {
      it.hoverScale.target = it.id === id ? 1.035 : 1;
    }
  }
  canvas.style.cursor = id ? 'pointer' : 'default';
});

canvas.addEventListener('mouseleave', () => {
  hoverId = null;
  for (const it of line.items) it.hoverScale.target = 1;
  line.closeGaps();
});

canvas.addEventListener('click', (e) => {
  const r = canvas.getBoundingClientRect();
  const mx = e.clientX - r.left;
  const my = e.clientY - r.top;
  const hit = hitTest(line, mx, my);
  if (!hit) return;
  const rect = line.rects.get(hit.id);
  // 左上角 26×26 是删除按钮
  if (rect && mx < rect.x + 26 && my < rect.y + 26) {
    line.drop(hit.id);
  } else {
    line.copy(hit.id);
  }
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
seed();

// 调试用：?settle=3 表示先把模拟快进 3 秒再画第一帧。
// 无头浏览器截图必须用它，否则拍到的永远是"刚挂上还没站稳"的瞬间。
const params = new URLSearchParams(location.search);

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

const settle = Number(params.get('settle') || 0);
if (settle > 0) line.advance(settle);

requestAnimationFrame(frame);

// 暴露给控制台，方便调试
window.__line = line;

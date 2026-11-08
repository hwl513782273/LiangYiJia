// 文字卡与链接卡：macOS 版是先渲染成一张图片再当照片挂上去
// （见 Sources/Tendedero/CardRenderer.swift）。这里照做，好处是挂上去以后
// 排版和图片卡完全一致，不用为两种卡片写两套绘制。
//
// 调用时机：收到复制内容时渲染一次，结果当成普通图片 item 挂上线，之后不再重排。

const W = 220;          // 逻辑宽度（等于 macOS 版的 cardWidth）
const PAD = 16;         // 内边距
const MAX_BODY = 116;   // 正文最多这么高，超了截断
const RADIUS = 10;      // 圆角
const SCALE = 2;        // 按 2 倍渲染，缩放后仍清晰

export function palette(dark) {
  return dark
    ? { bg: '#1E1E20', primary: '#EEEEF0', secondary: '#8B8B90', accent: '#65B4FF', border: 'rgba(255,255,255,0.08)' }
    : { bg: '#FFFFFF', primary: '#1C1C1E', secondary: '#8E8E93', accent: '#0A67C2', border: '#E3E3E7' };
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** 把一段文字按宽度折行，返回行数组。 */
function wrap(ctx, text, maxWidth) {
  const lines = [];
  for (const para of String(text).split(/\r?\n/)) {
    if (para === '') { lines.push(''); continue; }
    let line = '';
    for (const ch of para) {
      const test = line + ch;
      if (ctx.measureText(test).width > maxWidth && line) {
        lines.push(line);
        line = ch;
      } else {
        line = test;
      }
    }
    if (line) lines.push(line);
  }
  return lines;
}

function timeString(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 把文字整理一下：去掉多余空行、首尾空白。 */
function tidy(text) {
  return String(text)
    .replace(/\r\n/g, '\n')
    .split('\n')
    .map((l) => l.trimEnd())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function newCanvas(w, h) {
  const c = document.createElement('canvas');
  c.width = Math.round(w * SCALE);
  c.height = Math.round(h * SCALE);
  const ctx = c.getContext('2d');
  ctx.scale(SCALE, SCALE);
  return { canvas: c, ctx };
}

function drawBackground(ctx, w, h, pal) {
  roundRect(ctx, 0, 0, w, h, RADIUS);
  ctx.fillStyle = pal.bg;
  ctx.fill();
  ctx.strokeStyle = pal.border;
  ctx.lineWidth = 1;
  ctx.stroke();
}

/** 文字卡：表头「来源 · 时间」+ 正文 + 页脚。 */
export function makeTextCard({ text, source = '剪贴板', date = new Date(), dark = true }) {
  const pal = palette(dark);
  const body = tidy(text);

  // 先用一个临时 ctx 量出行数与高度
  const probe = document.createElement('canvas').getContext('2d');
  const bodyFont = '16px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  probe.font = bodyFont;
  let lines = wrap(probe, body, W - PAD * 2);
  let truncated = false;

  // 正文最多 MAX_BODY，超了就砍掉最后一行并加省略号
  const lineH = 22;
  if (lines.length * lineH > MAX_BODY) {
    const keep = Math.max(1, Math.floor(MAX_BODY / lineH));
    lines = lines.slice(0, keep);
    truncated = true;
    const last = lines[lines.length - 1];
    lines[lines.length - 1] = last.slice(0, Math.max(0, last.length - 1)) + '…';
  }

  const headerH = 14;
  const footerH = 13;
  const gap = 8;
  const bodyH = Math.max(lines.length * lineH + 6, 20);
  const total = PAD + headerH + gap + bodyH + gap + footerH + PAD;

  const { canvas, ctx } = newCanvas(W, total);
  drawBackground(ctx, W, total, pal);

  // 表头
  ctx.font = '10.5px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  ctx.fillStyle = pal.secondary;
  ctx.textBaseline = 'top';
  ctx.fillText(`${source} · ${timeString(date)}`, PAD, PAD);

  // 正文
  ctx.font = bodyFont;
  ctx.fillStyle = pal.primary;
  const bodyTop = PAD + headerH + gap;
  lines.forEach((l, i) => ctx.fillText(l, PAD, bodyTop + i * lineH));

  // 页脚
  ctx.font = '10.5px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  ctx.fillStyle = pal.secondary;
  const note = truncated ? '已截断 · 点开看全文' : `${body.length} 字`;
  ctx.fillText(note, PAD, bodyTop + bodyH + gap);

  return canvas;
}

/** 链接卡：域名 + 标题 + 路径。 */
export function makeLinkCard({ url, title = '', source = '剪贴板', date = new Date(), dark = true }) {
  const pal = palette(dark);
  let host = '';
  let path = '';
  try {
    const u = new URL(url);
    host = u.host.replace(/^www\./, '');
    path = u.pathname === '/' ? '' : u.pathname;
  } catch {
    host = url.slice(0, 40);
  }

  const titleFont = '600 15px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  const probe = document.createElement('canvas').getContext('2d');
  probe.font = titleFont;
  const titleLines = title ? wrap(probe, title, W - PAD * 2).slice(0, 4) : [];

  const headerH = 14;
  const hostH = 17;
  const urlH = 14;
  const gap = 6;
  const titleH = titleLines.length ? titleLines.length * 21 + 6 : 0;
  const total = PAD + headerH + gap + hostH + (titleH ? gap + titleH : 0) + gap + urlH + PAD;

  const { canvas, ctx } = newCanvas(W, total);
  drawBackground(ctx, W, total, pal);
  ctx.textBaseline = 'top';

  const small = '10.5px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  let y = PAD;

  ctx.font = small;
  ctx.fillStyle = pal.secondary;
  ctx.fillText(`${source} · ${timeString(date)}`, PAD, y);
  y += headerH + gap;

  ctx.font = '600 13px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  ctx.fillStyle = pal.accent;
  ctx.fillText(host, PAD, y);
  y += hostH;

  if (titleLines.length) {
    y += gap;
    ctx.font = titleFont;
    ctx.fillStyle = pal.primary;
    titleLines.forEach((l, i) => ctx.fillText(l, PAD, y + i * 21));
    y += titleH;
  }

  y += gap;
  ctx.font = small;
  ctx.fillStyle = pal.secondary;
  ctx.fillText(path.slice(0, 46), PAD, y);

  return canvas;
}

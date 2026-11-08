// 绘制：绳子、夹子、卡片，逐帧自绘。
// 对应 macOS 版 Sources/Tendedero/LineView.swift（绳子与布局）和 PeggedView.swift（卡片本体）。
//
// 调用时机：每一帧由 app.js 调一次 render()，画完顺手把每张卡片的矩形写回
// line.rects，供点击命中使用（macOS 版用的是 SwiftUI 的 PreferenceKey，思路一样）。

import { clamp } from './layout.js';

const FRAME = { radius: 16, inset: 4 };   // 卡片的玻璃边框：外圆角 16，照片内缩 4

/** 圆角矩形路径。 */
function roundRectPath(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/**
 * 绳子：一条抛物线，三段叠画（阴影 / 主线 / 高光），两端渐隐。
 * 渐隐不用遮罩，直接把曲线切成小段逐段改 alpha —— 省一层离屏画布，效果一样。
 */
function drawRope(ctx, w, ropeTop, sag) {
  const SEG = 180;
  const pts = [];
  for (let i = 0; i <= SEG; i++) {
    const t = i / SEG;
    // 二次贝塞尔：起点 -20、控制点 (w/2, ropeTop+2*sag)、终点 w+20
    const px = (1 - t) * (1 - t) * -20 + 2 * (1 - t) * t * (w / 2) + t * t * (w + 20);
    const py = (1 - t) * (1 - t) * ropeTop + 2 * (1 - t) * t * (ropeTop + 2 * sag) + t * t * ropeTop;
    pts.push([px, py]);
  }

  // 两端各 8% 渐隐，看起来像从屏幕外面拉过来的
  const fadeAt = (x) => {
    const f = x / w;
    if (f < 0.08) return f / 0.08;
    if (f > 0.92) return (1 - f) / 0.08;
    return 1;
  };

  const passes = [
    { color: '0,0,0', alpha: 0.13, width: 3.2, dy: 2.0 },      // 柔和投影（宽而淡）
    { color: '0,0,0', alpha: 0.20, width: 1.4, dy: 1.2 },      // 紧贴的影
    { color: '140,140,140', alpha: 1.0, width: 1.2, dy: 0 },   // 主线
    { color: '255,255,255', alpha: 0.45, width: 0.4, dy: -0.35 }, // 顶部高光
  ];

  ctx.lineCap = 'round';
  for (const p of passes) {
    for (let i = 0; i < SEG; i++) {
      const [x1, y1] = pts[i];
      const [x2, y2] = pts[i + 1];
      const a = p.alpha * fadeAt((x1 + x2) / 2);
      if (a <= 0.004) continue;
      ctx.strokeStyle = `rgba(${p.color},${a})`;
      ctx.lineWidth = p.width;
      ctx.beginPath();
      ctx.moveTo(x1, y1 + p.dy);
      ctx.lineTo(x2, y2 + p.dy);
      ctx.stroke();
    }
  }
}

/** 夹子：一颗拉丝金属胶囊，中间一道缝让绳子穿过去。钉住的用深空灰。 */
function drawClothespin(ctx, pinned) {
  const w = 9, h = 26, r = 3.5;
  const x = -w / 2, y = 0;

  // 投影
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,0.30)';
  ctx.shadowBlur = 4;
  ctx.shadowOffsetY = 1.5;
  roundRectPath(ctx, x, y, w, h, r);
  ctx.fillStyle = pinned ? '#5A5A5A' : '#C8C8C8';
  ctx.fill();
  ctx.restore();

  // 金属渐变（左亮右暗，模拟侧面受光）
  const g = ctx.createLinearGradient(x, 0, x + w, 0);
  const stops = pinned
    ? [0.30, 0.47, 0.38, 0.24]   // 深空灰
    : [0.70, 0.93, 0.82, 0.62];  // 银色
  const gray = (v) => `rgb(${Math.round(v * 255)},${Math.round(v * 255)},${Math.round(v * 255)})`;
  g.addColorStop(0, gray(stops[0]));
  g.addColorStop(0.35, gray(stops[1]));
  g.addColorStop(0.65, gray(stops[2]));
  g.addColorStop(1, gray(stops[3]));
  roundRectPath(ctx, x, y, w, h, r);
  ctx.fillStyle = g;
  ctx.fill();

  // 上下描边：上白下黑，做出一点圆柱感
  const e = ctx.createLinearGradient(0, y, 0, y + h);
  e.addColorStop(0, `rgba(255,255,255,${pinned ? 0.45 : 0.9})`);
  e.addColorStop(1, 'rgba(0,0,0,0.18)');
  roundRectPath(ctx, x, y, w, h, r);
  ctx.strokeStyle = e;
  ctx.lineWidth = 0.6;
  ctx.stroke();

  // 绳子穿过的缝
  ctx.beginPath();
  ctx.ellipse(0, 8.5 + 0.7, 2.5, 0.7, 0, 0, Math.PI * 2);
  ctx.fillStyle = `rgba(0,0,0,${pinned ? 0.55 : 0.32})`;
  ctx.fill();
}

/** 照片按比例塞进卡片区域。 */
export function photoSize(img, L) {
  const maxW = L.cardWidth - 14;
  const maxH = L.photoMaxHeight;
  const iw = img ? img.width : 0;
  const ih = img ? img.height : 0;
  if (!iw || !ih) return { w: maxW, h: maxH };
  const s = Math.min(maxW / iw, maxH / ih);
  return { w: iw * s, h: ih * s };
}

/** 画一张卡片（照片 + 玻璃边框 + 悬停按钮 + 已复制标记）。 */
function drawCard(ctx, item, L, state) {
  const { hovering, copied, dark } = state;
  const ps = photoSize(item.image, L);
  const cardW = ps.w + FRAME.inset * 2;
  const cardH = ps.h + FRAME.inset * 2;
  const cx = -cardW / 2;
  const cy = 14; // 夹子高 26、重叠 12，所以卡片顶在 14

  // ---- 玻璃底 + 投影 ----
  ctx.save();
  ctx.shadowColor = `rgba(0,0,0,${hovering ? 0.26 : 0.18})`;
  ctx.shadowBlur = (hovering ? 14 : 10) * 2;
  ctx.shadowOffsetY = hovering ? 8 : 5;
  roundRectPath(ctx, cx, cy, cardW, cardH, FRAME.radius);
  // 真实磨砂在 Windows 上做不到（整窗模糊会把空白处也糊掉），
  // 这里用半透明白当底，靠描边做出玻璃感。
  ctx.fillStyle = dark ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.55)';
  ctx.fill();
  ctx.restore();

  // ---- 照片 ----
  if (item.image) {
    ctx.save();
    roundRectPath(ctx, cx + FRAME.inset, cy + FRAME.inset, ps.w, ps.h, FRAME.radius - FRAME.inset);
    ctx.clip();
    ctx.drawImage(item.image, cx + FRAME.inset, cy + FRAME.inset, ps.w, ps.h);
    ctx.restore();

    // 照片内描边
    roundRectPath(ctx, cx + FRAME.inset, cy + FRAME.inset, ps.w, ps.h, FRAME.radius - FRAME.inset);
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.lineWidth = 0.5;
    ctx.stroke();
  }

  // ---- 玻璃描边：上白下透，像顶部有一道光 ----
  const g = ctx.createLinearGradient(0, cy, 0, cy + cardH);
  g.addColorStop(0, 'rgba(255,255,255,0.55)');
  g.addColorStop(1, 'rgba(255,255,255,0.12)');
  roundRectPath(ctx, cx, cy, cardW, cardH, FRAME.radius);
  ctx.strokeStyle = g;
  ctx.lineWidth = 0.75;
  ctx.stroke();

  // 外圈极淡的黑边，避免在浅色桌面上糊掉
  roundRectPath(ctx, cx - 0.5, cy - 0.5, cardW + 1, cardH + 1, FRAME.radius + 0.5);
  ctx.strokeStyle = 'rgba(0,0,0,0.10)';
  ctx.lineWidth = 0.5;
  ctx.stroke();

  // ---- 左上角的删除按钮（悬停才出现）----
  if (hovering) {
    const bx = cx + 3, by = cy + 3, s = 20;
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.18)';
    ctx.shadowBlur = 6;
    ctx.beginPath();
    ctx.arc(bx + s / 2, by + s / 2, s / 2, 0, Math.PI * 2);
    ctx.fillStyle = dark ? 'rgba(60,60,64,0.9)' : 'rgba(255,255,255,0.92)';
    ctx.fill();
    ctx.restore();

    ctx.beginPath();
    ctx.arc(bx + s / 2, by + s / 2, s / 2, 0, Math.PI * 2);
    ctx.strokeStyle = 'rgba(255,255,255,0.5)';
    ctx.lineWidth = 0.75;
    ctx.stroke();

    // 叉号
    const m = 6.5;
    ctx.beginPath();
    ctx.moveTo(bx + m, by + m);
    ctx.lineTo(bx + s - m, by + s - m);
    ctx.moveTo(bx + s - m, by + m);
    ctx.lineTo(bx + m, by + s - m);
    ctx.strokeStyle = dark ? 'rgba(240,240,242,0.95)' : 'rgba(28,28,30,0.85)';
    ctx.lineWidth = 1.6;
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  // ---- 已复制 ----
  if (copied) {
    const label = '已复制';
    ctx.font = '600 11px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
    const tw = ctx.measureText(label).width;
    const bw = tw + 26, bh = 22;
    const bx = -bw / 2, by = cy + cardH + 8;
    roundRectPath(ctx, bx, by, bw, bh, bh / 2);
    ctx.fillStyle = dark ? 'rgba(60,60,64,0.92)' : 'rgba(255,255,255,0.95)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(255,255,255,0.4)';
    ctx.lineWidth = 0.75;
    ctx.stroke();

    ctx.fillStyle = dark ? '#EEEEF0' : '#1C1C1E';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    // 打勾
    ctx.beginPath();
    ctx.moveTo(bx + 9, by + bh / 2);
    ctx.lineTo(bx + 12, by + bh / 2 + 3);
    ctx.lineTo(bx + 17, by + bh / 2 - 3.5);
    ctx.strokeStyle = dark ? 'rgba(120,220,150,0.95)' : 'rgba(30,150,80,0.95)';
    ctx.lineWidth = 1.8;
    ctx.lineCap = 'round';
    ctx.stroke();
    ctx.fillText(label, bx + 21, by + bh / 2 + 0.5);
    ctx.textAlign = 'start';
    ctx.textBaseline = 'alphabetic';
  }

  return { cardW, cardH };
}

/** 空线时的一句提示。 */
function drawHint(ctx, w, y, dark) {
  const text = '截个图，它就挂在这儿了';
  ctx.font = '500 12px -apple-system, "Microsoft YaHei", "Segoe UI", system-ui, sans-serif';
  const tw = ctx.measureText(text).width;
  const bw = tw + 24, bh = 24;
  roundRectPath(ctx, w / 2 - bw / 2, y, bw, bh, bh / 2);
  ctx.fillStyle = dark ? 'rgba(40,40,44,0.75)' : 'rgba(255,255,255,0.8)';
  ctx.fill();
  ctx.strokeStyle = dark ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.10)';
  ctx.lineWidth = 0.75;
  ctx.stroke();
  ctx.fillStyle = dark ? 'rgba(230,230,235,0.8)' : 'rgba(60,60,65,0.75)';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, w / 2, y + bh / 2 + 0.5);
  ctx.textAlign = 'start';
  ctx.textBaseline = 'alphabetic';
}

/**
 * 画一整帧。
 * @param line  数据模型
 * @param opts  { width, height, dark, hoverId, reveal }
 */
export function render(ctx, line, opts) {
  const { width: w, height: h, dark, hoverId } = opts;
  const L = line.layout;
  const sag = L.sag(w);

  ctx.clearRect(0, 0, w, h);

  // 收起时整条线往上藏，留 12px 不露头（与 macOS 版一致）
  const reveal = opts.reveal ?? 1;
  ctx.save();
  ctx.translate(0, -(1 - reveal) * (L.panelHeight + 12));

  drawRope(ctx, w, L.ropeTop, sag);

  if (line.items.length === 0) {
    drawHint(ctx, w, L.ropeY(w / 2, w) + 22, dark);
  }

  const visible = line.visibleCount;
  const pinned = line.pinnedLead;
  const count = line.items.length;

  line.rects.clear();

  // 普通卡先画、钉住的最后画（对应 macOS 版 zIndex：钉住的在上一层）
  const drawOrder = [];
  for (let i = 0; i < line.items.length; i++) if (!line.items[i].kept) drawOrder.push(i);
  for (let i = 0; i < line.items.length; i++) if (line.items[i].kept) drawOrder.push(i);

  drawOrder.forEach((index) => {
    const item = line.items[index];
    // 用弹簧当前位置，不用版式算出来的目标值：补位才是滑过去的
    const x = item.px.value;
    const ropeY = L.ropeY(x, w);
    const top = ropeY - L.pinAbove;

    // 滚到边缘时淡出，和 macOS 版同一套公式
    const edgeFade = clamp(Math.min(x, w - x) / 90, 0, 1);
    const hovering = hoverId === item.id && !item.falling;

    ctx.save();
    ctx.globalAlpha = edgeFade * (item.held ? 0.3 : 1);
    ctx.translate(x, top + item.arrived.value);
    ctx.rotate(((item.swing.value + item.tilt) * Math.PI) / 180);
    // 悬停放大以顶部为锚点：先缩放再画，原点就是锚点
    const hs = item.hoverScale.value;
    ctx.scale(hs, hs);

    const size = drawCard(ctx, item, L, {
      hovering,
      copied: line.copiedId === item.id,
      dark,
    });
    drawClothespin(ctx, item.kept);

    ctx.restore();

    // 回填矩形，供点击命中（不旋转，够用）
    line.rects.set(item.id, {
      x: x - size.cardW / 2,
      y: top + item.arrived.value + 14,
      w: size.cardW,
      h: size.cardH,
      rot: item.swing.value + item.tilt,
    });
  });

  // 掉落的卡片：自由落体 + 自转 + 淡出，画在所有东西上面
  for (const f of line.flights) {
    ctx.save();
    ctx.globalAlpha = f.alpha;
    ctx.translate(f.x + f.w / 2, f.y);
    ctx.rotate((f.rot * Math.PI) / 180);
    drawCard(ctx, f.item, L, { hovering: false, copied: false, dark });
    ctx.restore();
  }

  // 悬停放大预览：把这张卡放大显示全文（文字卡/链接卡）或原图（图片卡）。
  // 位置在「这张卡片的正下方」，不能盖住绳子和其他卡片 —— 上面那条带子是常驻的，
  // 一盖就看不见自己挂了什么了。尺寸也克制：最多 320×280，不再整屏糊一张。
  const hovered = hoverId == null ? null : line.items.find((i) => i.id === hoverId);
  if (hovered && hovered.preview) {
    // 预览图自带缩放系数：文字卡/链接卡按 2 倍渲染，图片卡是原始像素
    const pv = hovered.preview;
    const pw = pv.img.width / pv.scale;
    const ph = pv.img.height / pv.scale;

    const MAX_W = 320;
    const MAX_H = 280;
    const k = Math.min(1, MAX_W / pw, MAX_H / ph, (w - 24) / pw);
    const dw = pw * k;
    const dh = ph * k;

    // 贴在这张卡的下沿往下 10px；卡片矩形由 render 回填在 line.rects 里
    const own = line.rects.get(hovered.id);
    const cardBottom = own ? own.y + own.h : 130;
    let px = clamp((own ? own.x + own.w / 2 : hovered.px.value) - dw / 2, 12, Math.max(12, w - dw - 12));
    let py = cardBottom + 10;
    // 窗口不够高就往上收，但绝不上浮到盖住绳子和卡片
    if (py + dh > h - 8) py = Math.max(cardBottom + 10 - (py + dh - (h - 8)), h - dh - 8);

    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.34)';
    ctx.shadowBlur = 26;
    ctx.shadowOffsetY = 12;
    roundRectPath(ctx, px, py, dw, dh, 12);
    ctx.fillStyle = dark ? '#1E1E20' : '#FFFFFF';
    ctx.fill();
    ctx.shadowColor = 'transparent';
    ctx.drawImage(pv.img, px, py, dw, dh);
    ctx.restore();
  }

  ctx.restore();
}

/**
 * 点击命中测试：命中返回 item，否则 null。
 *
 * 顺序必须和绘制顺序一致：钉住的卡片画在最上层，命中也要先问它们。
 * 之前按 items 的数组顺序取第一张命中的，钉住的卡就会把它下面那张普通卡
 * 顶出来 —— 结果是钉住的卡片怎么点都没反应（像死了一样）。
 */
export function hitTest(line, mx, my) {
  const ordered = [
    ...line.items.filter((i) => i.kept),
    ...line.items.filter((i) => !i.kept),
  ];
  for (const it of ordered) {
    const r = line.rects.get(it.id);
    if (!r) continue;
    if (mx >= r.x && mx <= r.x + r.w && my >= r.y && my <= r.y + r.h) return it;
  }
  return null;
}

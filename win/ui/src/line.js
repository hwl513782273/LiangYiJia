// 线本身：挂着什么、怎么滚、什么时候让最老的一张掉下去。
// 对应 macOS 版 Sources/Tendedero/Line.swift（原型阶段先搬行为，磁盘读写与废纸篓后面接）。
//
// 调用时机：App 启动时 new Line()，之后每帧调用 tick(dt)。

import { makeLayout, easeInOut, clamp } from './layout.js';
import { Spring, SPRINGS } from './spring.js';

let nextId = 1;
const uid = () => `p${nextId++}`;

/** 挂在线上的一个东西：截图 / 文字 / 链接。 */
export class Item {
  constructor({ kind, image = null, title = '', source = '', text = '', url = '' }) {
    this.id = uid();
    this.kind = kind;              // 'image' | 'text' | 'link'
    this.image = image;            // 预渲染好的图片（截图或文字卡片的画布）
    this.title = title;
    this.source = source;
    this.text = text;
    this.url = url;

    // 每张照片都挂得有点歪，像真的挂在绳子上（-2.5° ~ 2.5°）
    this.tilt = (Math.random() - 0.5) * 5;

    this.kept = false;             // 钉住：永远不因为满了而掉
    this.falling = false;
    this.flying = false;
    this.held = false;

    // 视图状态（对应 PeggedView 里的 @State）
    this.swing = SPRINGS.swing(0); // 摆动角度
    this.arrived = SPRINGS.arrive(-46); // 落位时的纵向偏移：从 -46 弹到 0
    this.hoverScale = new Spring(200, 22, 1); // 悬停放大到 1.035
    // 横向位置也用弹簧跟：新卡片挤进来、旧的掉下去时，整排是"滑"过去的，
    // 不是瞬间跳到新位置。参数照抄 macOS 版 .spring(response: 0.55, dampingFraction: 0.78)。
    this.px = Spring.fromResponse(0.55, 0.78, 0);
    this.xInit = false;

    // 掉落状态：位置与速度在真正掉的那一刻由渲染层填
    this.fall = null;
  }
}

export class Line {
  constructor() {
    this.items = [];
    this.flights = [];   // 正在掉落的卡片（已经不在线上，位置由自己维护）
    this.width = 1200;
    this.size = 'medium';            // small / medium / large，菜单里可切
    this.layout = makeLayout(this.size);

    this.visibleCount = 8;   // 一屏放得下几张
    this.maxItems = 8;       // 最多保留几张
    this.keepOnLine = null;  // 菜单里设的保留数（25/50/100）；null = 一屏能放几张就几张

    this.scroll = 0;
    this.scrollTween = null; // {from,to,elapsed,dur}

    this.revealed = true;
    this.revealTween = null; // 收起/放下：0 = 收起，1 = 放下

    this.copiedId = null;
    this.copiedAt = 0;
    this.gustCount = 0;
    this.nextGust = 7 + Math.random() * 9;

    // 每张卡片此刻在窗口里的矩形，渲染层每帧回填；点击命中与掉落起点都用它
    this.rects = new Map();

    // 定时任务队列：不用 setTimeout，便于整条线暂停/继续
    this.timers = [];
    this.lettingGo = null;   // 正在清理的那张，避免同时清两张
    this.lastFall = 0;
    this.time = 0;
  }

  get liveCount() { return this.items.length; }

  /** 最老的、可以掉的那一张：跳过钉住的。 */
  oldestLoose() {
    return this.items.find((i) => !i.kept && !i.held);
  }

  get pinnedLead() {
    let n = 0;
    for (const i of this.items) { if (!i.kept) break; n++; }
    return n;
  }

  /** 延迟执行，走内部队列而不是 setTimeout。 */
  after(seconds, fn) {
    this.timers.push({ at: this.time + seconds, fn });
  }

  /** 窗口尺寸变了：重算布局与能放几张。 */
  resize(width) {
    this.width = width;
    this.layout = makeLayout(this.size);
    // 一屏能放几张：两边各留 100，再按间距算，夹在 3~12 之间（与 macOS 版一致）
    const usable = width - 200;
    const fits = clamp(Math.floor(usable / this.layout.spacing), 3, 12);
    this.visibleCount = fits;
    this.maxItems = Math.max(fits, this.keepOnLine ?? fits);
  }

  /** 挂上一个新东西。满了就让最老的那张下线。 */
  hang(item) {
    // 先去重：同样内容不重复挂（真机上用文件路径或文本哈希，这里用 id 由调用方保证）
    this.items.push(item);
    this.scrollTo(0);
    arrive(item);

    if (this.liveCount > this.maxItems && this.lettingGo == null) {
      const oldest = this.oldestLoose();
      if (oldest) this.letGo(oldest.id);
    }
    return item;
  }

  /**
   * 让某一张下线。
   * 有滚动时先滚到最老那一头（让人看清要掉的是哪张），停顿、照原样掉落、
   * 后面立刻补位、再滚回最新一头 —— 这就是"看得见的清理"。
   */
  letGo(id) {
    const scrolls = this.keepOnLine != null && this.items.length > this.visibleCount;
    if (!scrolls) {
      // 一眼看得全：最老的本来就在最前面，直接掉，但马上补位
      this.drop(id);
      this.sweepFallen();
      return;
    }

    this.lettingGo = id;
    // ① 滚到最老一头
    this.scrollTo(this.layout.frontScroll(this.items.length, this.visibleCount), 0.35, easeInOut);
    // ② 滚动走完再掉，卡片位置才对得上
    this.after(0.42, () => {
      const it = this.items.find((i) => i.id === id);
      if (!it) { this.lettingGo = null; return; }
      this.drop(id);
      // ③ 后面那张立刻补到最前面
      this.sweepFallen();
      this.scroll = Math.min(this.scroll, this.layout.frontScroll(this.items.length, this.visibleCount));
      this.lettingGo = null;
      // ④ 掉完了滚回最新一头
      this.after(0.9, () => {
        this.scrollTo(0, 0.35, easeInOut);
        if (this.liveCount > this.maxItems) {
          const next = this.oldestLoose();
          if (next) this.after(0.45, () => this.letGo(next.id));
        }
      });
    });
  }

  /**
   * 真正开始掉：把这张从线上摘下来、交给 flights 做自由落体。
   * 摘下来是立刻的 —— 后面那张马上补位（这就是"看得见的清理"里"立刻补位"那一步），
   * 而掉落的卡片还在最上层继续往下坠，互不影响。
   */
  drop(id) {
    const i = this.items.findIndex((x) => x.id === id);
    if (i < 0) return;
    const it = this.items[i];

    // 落点优先用渲染层每帧回填的真实矩形；没有（比如快进时还没渲染过）
    // 就用版式公式现场算一遍，保证掉落起点不会歪到屏幕中间。
    let r = this.rects.get(id);
    if (!r) {
      const L = this.layout;
      const px = it.px.value;
      const ropeY = L.ropeY(px, this.width);
      const top = ropeY - L.pinAbove;
      const cw = L.cardWidth, ch = L.photoMaxHeight + 8;
      r = { x: px - cw / 2, y: top + 14, w: cw, h: ch, rot: it.tilt };
    }

    this.items.splice(i, 1);
    this.lastFall = this.time;
    this.flights.push({
      item: it,
      x: r.x,
      y: r.y,
      w: r.w,
      h: r.h,
      rot: r.rot,
      vy: -70,                              // 先给一点向上的初速，看起来像"被摘下来"
      vr: (Math.random() - 0.5) * 60,       // 边掉边转
      alpha: 1,
    });
  }

  /** 兼容旧调用：现在掉落的已经不在 items 里了，不需要再扫。 */
  sweepFallen() {}

  /** 指针离开线：没有需要收的空位了（掉落的已即时摘除）。 */
  closeGaps() {}

  /** 平滑滚到某个偏移量。 */
  scrollTo(to, dur = 0.35, ease = easeInOut) {
    if (Math.abs(to - this.scroll) < 0.5) {
      this.scroll = to;
      this.scrollTween = null;
      return;
    }
    this.scrollTween = { from: this.scroll, to, elapsed: 0, dur, ease };
  }

  /** 一阵风：每 7~16 秒吹一次，所有卡片随机轻推一下。 */
  gust() {
    if (this.items.length === 0) return;
    this.gustCount++;
    for (const it of this.items) {
      if (it.falling) continue;
      const delay = Math.random() * 0.35;
      const deg = 1.6 + Math.random() * 1.8;
      this.after(delay, () => nudge(it, deg));
    }
  }

  /** 点击复制：给卡片盖一个"已复制"的小标。 */
  copy(id) {
    this.copiedId = id;
    this.copiedAt = this.time;
    this.after(1.2, () => { if (this.copiedId === id) this.copiedId = null; });
  }

  /**
   * 快进：按固定 1/60 秒步长把模拟推进 seconds 秒。
   * 用途是无头浏览器截图（那边 rAF 的时间不推进，只能这样把动画跑到稳定态），
   * 也可以用来做视觉回归的固定快照。
   */
  advance(seconds) {
    const step = 1 / 60;
    for (let s = 0; s < seconds; s += step) this.tick(step);
  }

  /** 每帧推进。 */
  tick(dt) {
    this.time += dt;

    // 定时任务
    if (this.timers.length) {
      const due = this.timers.filter((t) => t.at <= this.time);
      this.timers = this.timers.filter((t) => t.at > this.time);
      for (const t of due) t.fn();
    }

    // 风
    this.nextGust -= dt;
    if (this.nextGust <= 0) {
      this.gust();
      this.nextGust = 7 + Math.random() * 9;
    }

    // 滚动补间
    if (this.scrollTween) {
      const t = this.scrollTween;
      t.elapsed += dt;
      const p = clamp(t.elapsed / t.dur, 0, 1);
      this.scroll = t.from + (t.to - t.from) * t.ease(p);
      if (p >= 1) this.scrollTween = null;
    }

    // 每张卡片自己的弹簧
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];

      // 目标横坐标由版式算；第一帧直接落到目标位置，否则会从 0 飞过来
      const tx = this.layout.x(i, this.items.length, this.width, this.visibleCount,
                               this.scroll, this.pinnedLead, this.keepOnLine);
      if (!it.xInit) { it.px.jump(tx); it.xInit = true; } else { it.px.target = tx; }
      it.px.step(dt);

      it.swing.step(dt);
      it.arrived.step(dt);
      it.hoverScale.step(dt);

    }

    // 掉落的卡片：重力 + 自转 + 淡出，出了带子就回收
    for (const f of this.flights) {
      f.vy += 1200 * dt;   // 重力：比真实略夸张，2 秒内能掉出视线
      f.y += f.vy * dt;
      f.rot += f.vr * dt;
      f.alpha = clamp(1 - (f.y - 120) / 420, 0, 1);
    }
    if (this.flights.some((f) => f.alpha <= 0.02)) {
      this.flights = this.flights.filter((f) => f.alpha > 0.02);
    }
  }
}

/** 轻推一下：先推到 deg 度（0.3 秒），再弹回来。 */
export function nudge(item, deg) {
  item.swing.target = deg;
  item.swing.velocity = 0;
  // 0.3 秒后换成会回弹的弹簧，令归零
  item.swing.k = 2000;
  item.swing.c = 70;
  setTimeout(() => {
    item.swing.k = 38;
    item.swing.c = 2.4;
    item.swing.target = 0;
  }, 260);
}

/** 新卡片挂上：从上方弹入，同时大幅摆一下。 */
export function arrive(item) {
  item.arrived.target = 0;
  item.swing.jump(16);
  item.swing.target = 0;
}

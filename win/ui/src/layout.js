// 版式与几何：数值全部照抄 macOS 版 Sources/Tendedero/LineView.swift 的 Layout。
// 抄准了，两端卡片的间距、绳子的弧度才对得上，用户换系统不会觉得"变了个东西"。
//
// 调用时机：窗口尺寸变化时用 makeLayout() 生成一份，之后每帧绘制都拿它算坐标。

export const SIZE_SCALES = { small: 0.8, medium: 1, large: 1.35 };

export function makeLayout(size = 'medium') {
  const scale = SIZE_SCALES[size] ?? 1;

  // 卡片与绳子
  const photoMaxHeight = Math.round(104 * scale); // 照片区最大高度
  const cardWidth = Math.round(150 * scale);      // 一张卡占的宽度
  const spacing = cardWidth + 24;                 // 相邻两张的中心距
  const panelHeight = photoMaxHeight + 106;       // 整条带子的高度
  const ropeTop = 10;                             // 绳子两端的高度
  const pinAbove = 9.5;                           // 夹子顶端比绳子高多少

  // 绳子是一条抛物线：两端在 ropeTop，中间下垂 sag。
  // sag(width) 上限 30，屏幕越宽垂得越多但不会到失控。
  const sag = (width) => Math.min(30, width * 0.018);

  // 给定横坐标，绳子在这点的高度。f=0/1 时回到 ropeTop，f=0.5 时最深。
  const ropeY = (x, width) => {
    if (width <= 0) return ropeTop;
    const f = x / width;
    return ropeTop + 4 * sag(width) * f * (1 - f);
  };

  // 「固定住的那几张」是否真的要留在原地：
  // 只有它们不是全部、也没把右边挤没的时候才锚定，否则跟着一起滚。
  const anchorsPinned = (pinned, visible) => pinned > 0 && pinned < visible - 1;

  // 第 index 张卡片的中心横坐标。
  // keepOnLine 有值（菜单里设了保留 25/50/100）并且数量超出一屏时走"滚动"分支：
  // 最新一张固定在满屏时的位置，scroll 把更老的从左边带进来。
  // 否则走"挤一挤"分支：间距被压到能全部塞进屏幕。
  const x = (index, count, width, visible, scroll, pinned = 0, keepOnLine = null) => {
    if (keepOnLine != null && count > visible) {
      const newest = width / 2 + ((visible - 1) * spacing) / 2;
      if (anchorsPinned(pinned, visible) && index < pinned) {
        return newest - (visible - 1 - index) * spacing;
      }
      return newest - (count - 1 - index) * spacing + scroll;
    }
    const gaps = Math.max(count - 1, 0);
    const step = gaps > 0 ? Math.min(spacing, Math.max(0, width - 200) / gaps) : spacing;
    return width / 2 - (gaps * step) / 2 + index * step;
  };

  // 滚到"最老一头"需要的偏移量，用于超限清理时先把最老的带到眼前。
  const frontScroll = (count, visible) => Math.max(0, count - visible) * spacing;

  return {
    scale, photoMaxHeight, cardWidth, spacing, panelHeight, ropeTop, pinAbove,
    sag, ropeY, anchorsPinned, x, frontScroll,
  };
}

// ---- 缓动 ----
// 用于"滚到最老一头"这类固定时长的过渡（对应 Swift 的 easeInOut(duration:)）。
export const easeInOut = (t) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
export const easeOut = (t) => 1 - Math.pow(1 - t, 3);

// 把 v 限制在 [lo, hi]
export const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

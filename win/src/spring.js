// 弹簧：SwiftUI 的 .spring() / .interpolatingSpring() 在网页里没有对应物，
// 只能用数值积分自己算。这样摆动的"手感"才能和 macOS 版一致，而不是换成 CSS 的贝塞尔缓动。
//
// 调用时机：每一帧对每个需要动的量（摆动角度、落地偏移、悬停缩放）调用 step(dt)。

export class Spring {
  /**
   * @param stiffness 刚度（越大回得越快）
   * @param damping   阻尼（越大越快停，太小会一直晃）
   * @param value     初始值
   */
  constructor(stiffness, damping, value = 0) {
    this.k = stiffness;
    this.c = damping;
    this.value = value;
    this.target = value;
    this.velocity = 0;
  }

  /**
   * 用 SwiftUI 那套 (response, dampingFraction) 参数构造。
   * response = 一次完整摆动大约几秒；dampingFraction < 1 会来回晃。
   */
  static fromResponse(response, dampingFraction, value = 0) {
    const omega = (2 * Math.PI) / response;      // 自然角频率
    const k = omega * omega;                     // 刚度 = ω²
    const c = 2 * dampingFraction * omega;       // 阻尼 = 2ζω
    return new Spring(k, c, value);
  }

  /** 直接跳到某个值，不产生动画（用于"照原样掉落"这类瞬时切换）。 */
  jump(v) {
    this.value = v;
    this.target = v;
    this.velocity = 0;
  }

  /**
   * 推进一帧。
   * dt 用固定的 1/120 秒做子步长：60Hz 屏幕下每帧走两步，
   * 掉帧时也不会因为步长过大而发散。
   */
  step(dt) {
    const sub = 1 / 120;
    let left = Math.min(dt, 0.1); // 切后台回来时 dt 会很大，钳一下
    while (left > 0) {
      const h = Math.min(sub, left);
      const accel = -this.k * (this.value - this.target) - this.c * this.velocity;
      this.velocity += accel * h;
      this.value += this.velocity * h;
      left -= h;
    }
    // 已经停在目标附近就别再算了，省得一直有微小抖动
    if (Math.abs(this.value - this.target) < 0.001 && Math.abs(this.velocity) < 0.001) {
      this.value = this.target;
      this.velocity = 0;
    }
  }

  get settled() {
    return Math.abs(this.value - this.target) < 0.001 && Math.abs(this.velocity) < 0.001;
  }
}

// 对应 Swift 里 withAnimation(.spring(response:dampingFraction:)) 的常用几组参数，
// 保留成常量，改手感时只改这里。
export const SPRINGS = {
  /** 新卡片落位：response 0.42，略带回弹 */
  arrive: () => Spring.fromResponse(0.42, 0.72, -46),
  /** 挂上之后的摆动：刚度 46、阻尼 2.6，会来回晃好几下（这是"像真的挂上去"的关键） */
  swing: (v = 0) => new Spring(46, 2.6, v),
  /** 轻轻一推：刚度 38、阻尼 2.4 */
  nudge: (v = 0) => new Spring(38, 2.4, v),
};

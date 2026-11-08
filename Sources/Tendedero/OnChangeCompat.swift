import SwiftUI

/// 兼容 macOS 12 的「值变化回调」，行为与 macOS 14 的双参数 `onChange` 一致。
///
/// 为什么需要它：
/// macOS 14 引入的 `.onChange(of:) { 旧值, 新值 in }` 双参数闭包在 12 / 13 上**编译不过**；
/// 而 12 时代的旧写法 `.onChange(of:) { 新值 in }` 又只知道新值，判断不了「从什么变成什么」。
/// 这里在容器里自己记住上一次的值，对外仍然给出 (旧值, 新值) 两个参数，
/// 于是 12 / 13 / 14 / 15 / 26 用的都是同一段代码，不需要 `#available` 分叉。
///
/// 调用时机：视图里的某个值需要「和上一次比」时，用它替掉 `onChange`。
/// 注意它和双参数 `onChange` 一样，**首次出现时不触发**，只在值真的改变时触发。
struct ChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void

    // 上一次的值。SwiftUI 在视图身份不变时保留它，所以在同一次挂载里能跨刷新累积。
    @State private var previous: Value

    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        // 这里用单参数版本：它在 12 上可用，在 14 上只是被标为废弃，功能完全一样。
        content.onChange(of: value) { now in
            let was = previous
            previous = now
            action(was, now)
        }
    }
}

extension View {
    /// 用法同双参数 `onChange`：`view.onChangeCompat(of: x) { was, now in ... }`
    func onChangeCompat<V: Equatable>(of value: V,
                                      perform action: @escaping (V, V) -> Void) -> some View {
        modifier(ChangeObserver(value: value, action: action))
    }
}

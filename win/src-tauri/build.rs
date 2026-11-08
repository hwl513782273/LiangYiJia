// 用途：Tauri 构建脚本，生成 Windows 资源并把 tauri.conf.json 编译进程序。
// 调用时机：cargo build 时自动执行一次。
fn main() {
    tauri_build::build()
}

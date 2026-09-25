// Ultron TS UI experiment — native shell. The flashing core stays in Zig
// (../src); this shell only renders the webview frontend. A real IPC bridge
// (TCP/stdio to the Zig manager) is phase 2; today it loads the sim UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running ultron ui shell");
}

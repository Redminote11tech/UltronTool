// Ultron TS UI shell (Tauri 2).
//
// The shell renders the webview frontend and relays the Zig IPC daemon:
// it spawns zig-out/bin/ultron-daemon (or the sibling binary installed by
// the package), forwards daemon stdout lines to the webview as
// `daemon-event` payloads, and writes `daemon_send` command lines to its
// stdin. All flashing logic stays in the Zig core — this file is plumbing.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, RunEvent, State};

struct DaemonState {
    child: Mutex<Option<Child>>,
}

impl DaemonState {
    fn kill(&self) {
        if let Some(mut c) = self.child.lock().expect("daemon mutex").take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// Locate the daemon binary: env override → next to this executable
/// (installed package) → a zig-out build tree above us (development).
fn daemon_path() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("ULTRON_DAEMON_PATH") {
        let path = std::path::PathBuf::from(p);
        if path.is_file() {
            return Some(path);
        }
    }
    let exe = std::env::current_exe().ok()?;
    let mut dir = exe.parent()?.to_path_buf();
    for _ in 0..5 {
        for name in ["ultron-daemon", "ultrontool-beta-daemon"] {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
            let candidate = dir.join("zig-out/bin").join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        if !dir.pop() {
            break;
        }
    }
    None
}

fn spawn_daemon(app: AppHandle) {
    let Some(path) = daemon_path() else {
        eprintln!("ultron-ui: daemon binary not found (set ULTRON_DAEMON_PATH or build `zig build`)");
        let _ = app.emit("daemon-event", "{\"ev\":\"daemon_gone\",\"reason\":\"daemon binary not found\"}");
        return;
    };
    let child = Command::new(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn();

    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            let _ = app.emit(
                "daemon-event",
                format!("{{\"ev\":\"daemon_gone\",\"reason\":\"spawn failed: {}\"}}", e),
            );
            return;
        }
    };

    // stdout → webview events.
    if let Some(out) = child.stdout.take() {
        let app_out = app.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(out);
            for line in reader.lines() {
                match line {
                    Ok(l) => {
                        if app_out.emit("daemon-event", &l).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let _ = app_out.emit("daemon-event", "{\"ev\":\"daemon_gone\",\"reason\":\"daemon exited\"}");
        });
    }

    let state: State<DaemonState> = app.state();
    *state.child.lock().expect("daemon mutex") = Some(child);
}

#[tauri::command]
fn daemon_send(line: String, state: State<DaemonState>) -> Result<(), String> {
    let guard = state.child.lock().map_err(|_| "mutex poisoned")?;
    let child = guard.as_ref().ok_or("daemon not running")?;
    let mut stdin = child.stdin.as_ref().ok_or("daemon stdin closed")?;
    let mut full = line;
    full.push('\n');
    stdin.write_all(full.as_bytes()).map_err(|e| e.to_string())?;
    stdin.flush().map_err(|e| e.to_string())
}

fn main() {
    // WebKitGTK's DMABUF renderer is the known source of blank/garbled windows
    // (and WebProcess SIGSEGVs inside libEGL) on NVIDIA + Wayland — the
    // Tauri-documented workaround is to disable it. Default it on unless the
    // user picked a mode themselves (env already set, or ULTRON_WEBKIT_COMPAT
    // set to "off" / "raw" to skip all defaults).
    let compat = std::env::var("ULTRON_WEBKIT_COMPAT").unwrap_or_default();
    if compat != "off" && compat != "raw" {
        if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(DaemonState { child: Mutex::new(None) })
        .invoke_handler(tauri::generate_handler![daemon_send])
        .setup(|app| {
            spawn_daemon(app.handle().clone());
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building ultron ui shell")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                app.state::<DaemonState>().kill();
            }
        });
}

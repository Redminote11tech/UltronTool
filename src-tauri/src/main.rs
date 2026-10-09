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
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State};

struct DaemonState {
    child: Mutex<Option<Child>>,
    active_request: Mutex<Option<u64>>,
    started: Mutex<bool>,
    closing: AtomicBool,
    snapshot: Mutex<Vec<serde_json::Value>>,
}

#[tauri::command]
fn daemon_close(app: AppHandle, state: State<DaemonState>) -> Result<(), String> {
    if state.closing.swap(true, Ordering::AcqRel) {
        return Ok(());
    }
    let mut child = state
        .child
        .lock()
        .map_err(|_| "daemon mutex poisoned")?
        .take();
    if let Some(ref mut child) = child {
        if let Some(mut stdin) = child.stdin.take() {
            // Cancel cooperatively and wait for worker cleanup. Never kill a flash.
            let _ = stdin.write_all(b"{\"cmd\":\"cancel\"}\n{\"cmd\":\"shutdown\"}\n");
            let _ = stdin.flush();
        }
    }
    std::thread::spawn(move || {
        if let Some(mut child) = child {
            let _ = child.wait();
        }
        app.exit(0);
    });
    Ok(())
}

// Cache only current state; replay never replays old job completions.
fn relay(app: &AppHandle, value: serde_json::Value) {
    let state = app.state::<DaemonState>();
    let mut snapshot = state.snapshot.lock().expect("snapshot mutex");
    let event = value["ev"].as_str().unwrap_or("");
    match event {
        "device_added" | "device_removed" => {
            snapshot.retain(|old| !(old["ev"] == "device_added" && old["path"] == value["path"]));
            if event == "device_added" {
                snapshot.push(value.clone());
            }
        }
        "hello" | "state" | "session_config" | "chip_info" | "partitions" | "daemon_gone" => {
            if event == "state" && value["state"] == "disconnected" {
                snapshot.retain(|old| {
                    old["ev"] != "partitions"
                        && old["ev"] != "chip_info"
                        && old["ev"] != "session_config"
                });
            }
            snapshot.retain(|old| old["ev"] != event);
            snapshot.push(value.clone());
        }
        _ => {}
    }
    let _ = app.emit("daemon-event", value.to_string());
}

#[tauri::command]
fn daemon_start(app: AppHandle, state: State<DaemonState>) {
    let mut started = state.started.lock().expect("start mutex");
    if !*started {
        *started = true;
        spawn_daemon(app.clone());
    } else {
        let snapshot = state.snapshot.lock().expect("snapshot mutex");
        for value in snapshot.iter() {
            let _ = app.emit("daemon-event", value.to_string());
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
        eprintln!(
            "ultron-ui: daemon binary not found (set ULTRON_DAEMON_PATH or build `zig build`)"
        );
        relay(
            &app,
            serde_json::json!({"ev":"daemon_gone","reason":"daemon binary not found"}),
        );
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
            relay(
                &app,
                serde_json::json!({"ev":"daemon_gone","reason":format!("spawn failed: {e}")}),
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
                        let mut value: serde_json::Value = match serde_json::from_str(&l) {
                            Ok(value) => value,
                            Err(_) => continue,
                        };
                        if value["ev"] == "finished" {
                            let state = app_out.state::<DaemonState>();
                            let id = state.active_request.lock().expect("request mutex").take();
                            value["request_id"] = serde_json::json!(id);
                        }
                        relay(&app_out, value);
                    }
                    Err(_) => break,
                }
            }
            relay(
                &app_out,
                serde_json::json!({"ev":"daemon_gone","reason":"daemon exited"}),
            );
        });
    }

    let state: State<DaemonState> = app.state();
    *state.child.lock().expect("daemon mutex") = Some(child);
}

#[tauri::command]
fn daemon_send(line: String, state: State<DaemonState>) -> Result<(), String> {
    if state.closing.load(Ordering::Acquire) {
        return Err("application is closing".into());
    }
    let request: serde_json::Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    let command = request["cmd"].as_str().ok_or("missing command")?;
    let is_job = !matches!(command, "cancel" | "shutdown");
    let mut active = state
        .active_request
        .lock()
        .map_err(|_| "request mutex poisoned")?;
    if is_job {
        if active.is_some() {
            return Err("another operation is running".into());
        }
        *active = Some(request["request_id"].as_u64().ok_or("missing request ID")?);
    }
    let result = (|| {
        let guard = state.child.lock().map_err(|_| "mutex poisoned")?;
        let child = guard.as_ref().ok_or("daemon not running")?;
        let mut stdin = child.stdin.as_ref().ok_or("daemon stdin closed")?;
        let mut full = line;
        full.push('\n');
        stdin
            .write_all(full.as_bytes())
            .map_err(|e| e.to_string())?;
        stdin.flush().map_err(|e| e.to_string())
    })();
    if result.is_err() && is_job {
        *active = None;
    }
    result
}

#[tauri::command]
fn save_log(path: String, contents: String) -> Result<(), String> {
    std::fs::write(path, contents).map_err(|error| error.to_string())
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
        .manage(DaemonState {
            child: Mutex::new(None),
            active_request: Mutex::new(None),
            started: Mutex::new(false),
            closing: AtomicBool::new(false),
            snapshot: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![
            daemon_send,
            daemon_start,
            daemon_close,
            save_log
        ])
        .build(tauri::generate_context!())
        .expect("error while building ultron ui shell")
        .run(|app, event| {
            let state = app.state::<DaemonState>();
            match event {
                RunEvent::WindowEvent {
                    event: tauri::WindowEvent::CloseRequested { api, .. },
                    ..
                } => {
                    api.prevent_close();
                    if !state.closing.load(Ordering::Acquire) {
                        if state
                            .active_request
                            .lock()
                            .expect("request mutex")
                            .is_some()
                        {
                            let _ = app.emit("app-close-requested", ());
                        } else {
                            let _ = daemon_close(app.clone(), state);
                        }
                    }
                }
                RunEvent::ExitRequested { api, .. } if !state.closing.load(Ordering::Acquire) => {
                    api.prevent_exit();
                    let _ = daemon_close(app.clone(), state);
                }
                _ => {}
            }
        });
}

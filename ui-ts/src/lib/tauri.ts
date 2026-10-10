/** Tauri bridge helpers. Everything degrades gracefully: in a plain browser
 * (vite dev) isTauri() is false and the app runs the simulated bus. */

export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Subscribe to daemon stdout lines (already relayed by the Rust shell). */
export function daemonListen(onLine: (line: string) => void): () => void {
  if (!isTauri()) return () => {};
  let unlisten: (() => void) | null = null;
  let cancelled = false;
  void import("@tauri-apps/api/event").then(({ listen }) =>
    listen<string>("daemon-event", (e) => onLine(e.payload)).then((u) => {
      if (cancelled) u();
      else {
        unlisten = u;
        // Spawn/replay only after the listener is installed. StrictMode's
        // cancelled first subscription must never start a backend.
        void import("@tauri-apps/api/core").then(({ invoke }) => invoke("daemon_start")).catch(error => {
          if (!cancelled) onLine(JSON.stringify({ ev: "daemon_gone", reason: String(error) }));
        });
      }
    }),
  ).catch(error => {
    if (!cancelled) onLine(JSON.stringify({ ev: "daemon_gone", reason: String(error) }));
  });
  return () => {
    cancelled = true;
    unlisten?.();
  };
}

/** Send one command line to the daemon's stdin. */
export async function daemonSend(cmd: unknown): Promise<void> {
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("daemon_send", { line: JSON.stringify(cmd) });
}

export interface FileFilter {
  name: string;
  extensions: string[];
}

/** Native file picker (Tauri plugin-dialog); returns paths or null. */
export async function pickFiles(opts: {
  multiple?: boolean;
  directory?: boolean;
  filters?: FileFilter[];
  title?: string;
}): Promise<string[]> {
  const { open } = await import("@tauri-apps/plugin-dialog");
  const res = await open({
    multiple: opts.multiple ?? false,
    directory: opts.directory ?? false,
    filters: opts.filters,
    title: opts.title,
  });
  if (res === null) return [];
  return Array.isArray(res) ? res : [res];
}

/** Export every retained line; the native save dialog chooses the destination. */
export async function saveLog(contents: string): Promise<boolean> {
  if (isTauri()) {
    const { save } = await import("@tauri-apps/plugin-dialog");
    const path = await save({ title: "Save session log", defaultPath: "ultron-session.log", filters: [{ name: "Log", extensions: ["log", "txt"] }] });
    if (!path) return false;
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("save_log", { path, contents });
  } else {
    const url = URL.createObjectURL(new Blob([contents], { type: "text/plain;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url; link.download = "ultron-session.log"; link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return true;
}

export async function pickSavePath(defaultPath: string): Promise<string | null> {
  const {save} = await import("@tauri-apps/plugin-dialog");
  return save({title:"Save partition backup",defaultPath,filters:[{name:"Raw partition image",extensions:["img","bin"]}]});
}

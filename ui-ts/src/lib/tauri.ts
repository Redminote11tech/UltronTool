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
      else unlisten = u;
    }),
  );
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

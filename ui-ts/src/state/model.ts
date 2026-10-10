import { canSelectDevice } from "./jobGate.ts";
import { VENDORS } from "./vendors.ts";
import type { Mode } from "./vendors.ts";
import type { DaemonDevice, SessionState } from "./daemon";

export type Level = "info" | "ok" | "warn" | "error" | "protocol";
export type Page = "device" | "flash" | "partitions" | "console";
export type Storage = "ufs" | "emmc" | "spinor" | "nand" | "nvme";
export type Source = "sim" | "daemon";

export interface LogLine {
  id: number;
  at: number;
  level: Level;
  text: string;
}

export interface Job {
  title: string;
  label: string;
  value: number;
  fraction: number | null;
  total: number;
  rate: number;
  eta: number;
  failed: boolean;
  finished: boolean;
  message: string;
}

export interface Toast {
  id: number;
  ok: boolean;
  title: string;
  body?: string;
}

export interface PartRow {
  name: string;
  first_lba: number;
  last_lba: number;
}

export interface StagedFile { name: string; size: number; paths: string[] }
export interface FlashDraft {
  scope: string; files: Record<string, StagedFile | null>; storage: Storage; skipInit: boolean;
}
const emptyDraft = (scope: string): FlashDraft => ({ scope, files: {}, storage: "ufs", skipInit: false });

export interface State {
  page: Page;
  draft: FlashDraft;
  /* sim */
  mode: Mode;
  scanning: boolean;
  chip: string | null;
  /* shared */
  logs: LogLine[];
  job: Job | null;
  toasts: Toast[];
  /* daemon */
  source: Source;
  devices: DaemonDevice[];
  selectedPath: string | null;
  session: SessionState;
  configured: { storage: Storage; skipInit: boolean; vipDir: string } | null;
  daemonGone: string | null;
  parts: { lun: number; sector_size: number; luns: number; vip: boolean; rows: PartRow[] } | null;
}

export type Action =
  | { type: "draftFiles"; scope: string; update: (files: FlashDraft["files"]) => FlashDraft["files"] }
  | { type: "draftSettings"; scope: string; storage?: Storage; skipInit?: boolean }
  | { type: "page"; page: Page }
  | { type: "log"; level: Level; text: string }
  | { type: "clearLogs" }
  | { type: "scanStart" }
  | { type: "scanFound"; mode: Mode; chip: string }
  | { type: "disconnect" }
  | { type: "jobStart"; title: string; total: number }
  | { type: "jobProgress"; label: string; value: number; rate: number; eta: number; total?: number; fraction?: number | null }
  | { type: "jobDismiss" }
  | { type: "jobEnd"; failed: boolean; message?: string }
  | { type: "toast"; toast: Toast }
  | { type: "toastGone"; id: number }
  | { type: "sourceSet"; source: Source; protocolVersion?: number }
  | { type: "devAdd"; dev: DaemonDevice }
  | { type: "devRemove"; path: string }
  | { type: "devSelect"; path: string | null }
  | { type: "sessionTarget"; path: string }
  | { type: "configured"; storage: Storage; skipInit: boolean; vipDir: string }
  | { type: "session"; session: SessionState }
  | { type: "chipEv"; chip: string }
  | { type: "partsEv"; lun: number; sector_size: number; luns: number; vip: boolean; rows: PartRow[] }
  | { type: "daemonGone"; reason: string };

export const CHIP_NAMES: Record<Exclude<Mode, "none">, string> = {
  qualcomm_edl: "SM8250 · Sahara v2.1",
  qualcomm_crash: "SM8250 · ramdump",
  samsung: "Exynos 2100 · Loke v2",
  lg: "SDM845 · LAF 1.1",
  mtk: "MT6785 · hw_code 0x0717",
  spd: "UMS512 · BSL v1.0",
};

let logId = 0;

export function createInitial(source: Source): State {
  return {
    page: "device",
    draft: emptyDraft(`${source}:none`),
    mode: "none",
    scanning: false,
    chip: null,
    logs: [
      { id: logId++, at: Date.now(), level: "info", text: source === "sim" ? "ultron ui — simulated bus (browser preview)" : "daemon: starting device service…" },
    ],
    job: null,
    toasts: [],
    source,
    devices: [],
    selectedPath: null,
    session: "disconnected",
    configured: null,
    daemonGone: null,
    parts: null,
  };
}

export const initial = createInitial("sim");

function pushLog(s: State, level: Level, text: string): LogLine[] {
  const next = [...s.logs, { id: logId++, at: Date.now(), level, text }];
  return next.length > 600 ? next.slice(next.length - 600) : next;
}

export function reducer(s: State, a: Action): State {
  switch (a.type) {
    case "draftFiles": return a.scope === s.draft.scope ? { ...s, draft: { ...s.draft, files: a.update(s.draft.files) } } : s;
    case "draftSettings": return a.scope === s.draft.scope ? { ...s, draft: { ...s.draft, storage: a.storage ?? s.draft.storage, skipInit: a.skipInit ?? s.draft.skipInit } } : s;
    case "page":
      return { ...s, page: a.page };
    case "log":
      return { ...s, logs: pushLog(s, a.level, a.text) };
    case "clearLogs":
      return { ...s, logs: [] };
    case "scanStart":
      return { ...s, scanning: true, mode: "none", chip: null, logs: pushLog(s, "info", "usb: hotplug monitor — waiting for a download-mode device…") };
    case "scanFound": {
      const v = VENDORS[a.mode as Exclude<Mode, "none">];
      let logs = pushLog(s, "info", `usb: device ${v.name} detected — class match, claiming interface`);
      logs = pushLog({ ...s, logs }, "info", `probe: ${a.chip}`);
      return { ...s, draft: emptyDraft(`sim:${a.mode}`), scanning: false, mode: a.mode, chip: a.chip, logs };
    }
    case "disconnect":
      return { ...s, scanning: false, mode: "none", chip: null, logs: pushLog(s, "info", "usb: device removed — interface released") };
    case "jobStart":
      return {
        ...s,
        job: { title: a.title, label: "Preparing…", value: 0, fraction: null, total: a.total, rate: 0, eta: 0, failed: false, finished: false, message: "" },
        logs: pushLog(s, "info", `job: ${a.title}`),
      };
    case "jobProgress":
      return s.job ? { ...s, job: { ...s.job, label: a.label, value: a.value, total: a.total ?? s.job.total, fraction: a.fraction !== undefined ? a.fraction : s.job.total > 0 ? a.value / s.job.total : null, rate: a.rate, eta: a.eta } } : s;
    case "jobDismiss":
      return s.job?.finished ? {...s,job:null} : s;
    case "jobEnd":
      if (!s.job) return s;
      return {
        ...s,
        job: { ...s.job, finished: true, failed: a.failed, message: a.message ?? "", fraction: a.failed ? s.job.fraction : 1, value: a.failed ? s.job.value : s.job.total },
        logs: pushLog(s, a.failed ? "error" : "ok", a.failed ? `job: ${s.job.title} — FAILED` : `job: ${s.job.title} — finished`),
      };
    case "toast":
      return { ...s, toasts: [...s.toasts.slice(-3), a.toast] };
    case "toastGone":
      return { ...s, toasts: s.toasts.filter((t) => t.id !== a.id) };
    case "sourceSet":
      return { ...s, source: a.source, logs: pushLog(s, "info", a.source === "daemon" ? `daemon: attached — real device bus (protocol v${a.protocolVersion ?? 1})` : "ultron ui — simulated bus (browser preview)") };
    case "devAdd": {
      const devices = s.devices.filter((d) => d.path !== a.dev.path).concat(a.dev);
      return { ...s, devices, logs: pushLog(s, "info", `usb: ${a.dev.label} — ${a.dev.vid.toString(16).padStart(4, "0")}:${a.dev.pid.toString(16).padStart(4, "0")}`) };
    }
    case "devRemove": {
      const devices = s.devices.filter((d) => d.path !== a.path);
      const selectedPath = s.selectedPath === a.path ? null : s.selectedPath;
      const removedSelected = s.selectedPath === a.path;
      return { ...s, devices, selectedPath, ...(removedSelected ? { session: "disconnected" as const, configured: null, parts: null, chip: null } : {}), logs: pushLog(s, "info", "usb: device removed — interface released") };
    }
    case "sessionTarget":
      return { ...s, selectedPath: a.path, draft: { ...s.draft, scope: `daemon:${a.path}` } };
    case "devSelect":
      return canSelectDevice(s.selectedPath, a.path, s.session, !!s.job && !s.job.finished)
        ? { ...s, draft: s.selectedPath === a.path ? s.draft : emptyDraft(`daemon:${a.path}`), selectedPath: a.path, parts: null, chip: null } : s;
    case "configured":
      return { ...s, configured: { storage: a.storage, skipInit: a.skipInit, vipDir: a.vipDir }, draft: { ...s.draft, storage: a.storage, skipInit: a.skipInit } };
    case "session":
      return { ...s, configured: a.session === "disconnected" ? null : s.configured, session: a.session, logs: pushLog(s, "info", `session: ${a.session}`) };
    case "chipEv":
      return { ...s, chip: a.chip, logs: pushLog(s, "info", `probe: ${a.chip}`) };
    case "partsEv":
      return {
        ...s,
        parts: { lun: a.lun, sector_size: a.sector_size, luns: a.luns, vip: a.vip, rows: a.rows },
        logs: pushLog(s, a.vip ? "warn" : "info", a.vip ? "VIP session — partition browsing disabled, rawprogram flash only" : `gpt: ${a.rows.length} partitions on LUN ${a.lun} (${a.sector_size} B sectors, ${a.luns} LUNs)`),
      };
    case "daemonGone":
      return { ...s, job: s.job ? { ...s.job, finished: true, failed: true } : null, parts: null, selectedPath: null, daemonGone: a.reason, session: "disconnected", devices: [], logs: pushLog(s, "error", `daemon: gone — ${a.reason}`) };
  }
}


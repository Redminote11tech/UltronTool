/** App state bus. Two transports feed the same reducer:
 *  - daemon (real): line-JSON events from the Zig ultron-daemon via Tauri
 *  - sim (design iteration in a plain browser): scripted scenarios
 * Pages are transport-agnostic except where they check `source`. */
import { createContext, useContext, useMemo, useReducer, useRef } from "react";
import type { ReactNode } from "react";
import { SCENARIOS, VENDORS } from "./vendors";
import type { Mode } from "./vendors";
import { isTauri } from "../lib/tauri";
import { onDaemonEvent, sendDaemon } from "./daemon";
import type { DaemonDevice, SessionState } from "./daemon";

export type Level = "info" | "ok" | "warn" | "error" | "protocol";
export type Page = "device" | "flash" | "console";
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
  total: number;
  rate: number;
  eta: number;
  failed: boolean;
  finished: boolean;
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

export interface State {
  page: Page;
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
  daemonGone: string | null;
  parts: { lun: number; sector_size: number; luns: number; vip: boolean; rows: PartRow[] } | null;
}

type Action =
  | { type: "page"; page: Page }
  | { type: "log"; level: Level; text: string }
  | { type: "clearLogs" }
  | { type: "scanStart" }
  | { type: "scanFound"; mode: Mode; chip: string }
  | { type: "disconnect" }
  | { type: "jobStart"; title: string; total: number }
  | { type: "jobProgress"; label: string; value: number; rate: number; eta: number }
  | { type: "jobEnd"; failed: boolean }
  | { type: "toast"; toast: Toast }
  | { type: "toastGone"; id: number }
  | { type: "sourceSet"; source: Source }
  | { type: "devAdd"; dev: DaemonDevice }
  | { type: "devRemove"; path: string }
  | { type: "devSelect"; path: string | null }
  | { type: "session"; session: SessionState }
  | { type: "chipEv"; chip: string }
  | { type: "partsEv"; lun: number; sector_size: number; luns: number; vip: boolean; rows: PartRow[] }
  | { type: "daemonGone"; reason: string };

const CHIP_NAMES: Record<Exclude<Mode, "none">, string> = {
  qualcomm_edl: "SM8250 · Sahara v2.1",
  qualcomm_crash: "SM8250 · ramdump",
  samsung: "Exynos 2100 · Loke v2",
  lg: "SDM845 · LAF 1.1",
  mtk: "MT6785 · hw_code 0x0717",
  spd: "UMS512 · BSL v1.0",
};

let logId = 0;
let toastId = 0;

const initial: State = {
  page: "device",
  mode: "none",
  scanning: false,
  chip: null,
  logs: [
    { id: logId++, at: Date.now(), level: "info", text: "ultron ui — simulated bus (browser preview)" },
  ],
  job: null,
  toasts: [],
  source: "sim",
  devices: [],
  selectedPath: null,
  session: "disconnected",
  daemonGone: null,
  parts: null,
};

function pushLog(s: State, level: Level, text: string): LogLine[] {
  const next = [...s.logs, { id: logId++, at: Date.now(), level, text }];
  return next.length > 600 ? next.slice(next.length - 600) : next;
}

function reducer(s: State, a: Action): State {
  switch (a.type) {
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
      return { ...s, scanning: false, mode: a.mode, chip: a.chip, logs };
    }
    case "disconnect":
      return { ...s, scanning: false, mode: "none", chip: null, logs: pushLog(s, "info", "usb: device removed — interface released") };
    case "jobStart":
      return {
        ...s,
        job: { title: a.title, label: "Preparing…", value: 0, total: a.total, rate: 0, eta: 0, failed: false, finished: false },
        logs: pushLog(s, "info", `job: ${a.title}`),
      };
    case "jobProgress":
      return s.job ? { ...s, job: { ...s.job, label: a.label, value: a.value, rate: a.rate, eta: a.eta } } : s;
    case "jobEnd":
      if (!s.job) return s;
      return {
        ...s,
        job: { ...s.job, finished: true, failed: a.failed, value: a.failed ? s.job.value : s.job.total },
        logs: pushLog(s, a.failed ? "error" : "ok", a.failed ? `job: ${s.job.title} — FAILED` : `job: ${s.job.title} — finished`),
      };
    case "toast":
      return { ...s, toasts: [...s.toasts.slice(-3), a.toast] };
    case "toastGone":
      return { ...s, toasts: s.toasts.filter((t) => t.id !== a.id) };
    case "sourceSet":
      return { ...s, source: a.source, logs: pushLog(s, "info", `daemon: attached — real device bus (protocol v1)`) };
    case "devAdd": {
      const devices = s.devices.filter((d) => d.path !== a.dev.path).concat(a.dev);
      return { ...s, devices, logs: pushLog(s, "info", `usb: ${a.dev.label} — ${a.dev.vid.toString(16).padStart(4, "0")}:${a.dev.pid.toString(16).padStart(4, "0")}`) };
    }
    case "devRemove": {
      const devices = s.devices.filter((d) => d.path !== a.path);
      const selectedPath = s.selectedPath === a.path ? null : s.selectedPath;
      return { ...s, devices, selectedPath, session: "disconnected", logs: pushLog(s, "info", "usb: device removed — interface released") };
    }
    case "devSelect":
      return { ...s, selectedPath: a.path };
    case "session":
      return { ...s, session: a.session, logs: pushLog(s, "info", `session: ${a.session}`) };
    case "chipEv":
      return { ...s, chip: a.chip, logs: pushLog(s, "info", `probe: ${a.chip}`) };
    case "partsEv":
      return {
        ...s,
        parts: { lun: a.lun, sector_size: a.sector_size, luns: a.luns, vip: a.vip, rows: a.rows },
        logs: pushLog(s, a.vip ? "warn" : "info", a.vip ? "VIP session — partition browsing disabled, rawprogram flash only" : `gpt: ${a.rows.length} partitions on LUN ${a.lun} (${a.sector_size} B sectors, ${a.luns} LUNs)`),
      };
    case "daemonGone":
      return { ...s, daemonGone: a.reason, session: "disconnected", devices: [], logs: pushLog(s, "error", `daemon: gone — ${a.reason}`) };
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const jitter = (base: number, spread: number) => base + (Math.random() - 0.5) * spread;

export interface FlashPlan {
  programmer?: string;
  files: string[];
  storage: Storage;
  skipInit: boolean;
  vipDir?: string;
}

interface Api {
  state: State;
  dispatch: React.Dispatch<Action>;
  /* sim */
  setMode: (m: Mode) => void;
  startFlash: () => void;
  /* daemon */
  connectDevice: (dev: DaemonDevice) => void;
  uploadLoader: (programmer: string, storage: Storage, skipInit: boolean, vipDir?: string) => void;
  disconnectDevice: () => void;
  resetDevice: () => void;
  startFlashReal: (plan: FlashPlan) => void;
  cancelFlash: () => void;
  toast: (ok: boolean, title: string, body?: string) => void;
}

const Ctx = createContext<Api | null>(null);

export function BusProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, initial);
  const stateRef = useRef(state);
  stateRef.current = state;

  const runToken = useRef(0);
  const pendingFlash = useRef<{ files: string[]; storage: Storage; skipInit: boolean } | null>(null);
  const lastTick = useRef<{ at: number; done: number } | null>(null);

  const api = useMemo<Api>(() => {
    const toast = (ok: boolean, title: string, body?: string) =>
      dispatch({ type: "toast", toast: { id: ++toastId, ok, title, body } });

    // ------------------------------------------------------------- sim
    const setMode = (m: Mode) => {
      if (stateRef.current.source !== "sim") return;
      void (async () => {
        const token = ++runToken.current;
        if (m === "none") {
          dispatch({ type: "disconnect" });
          return;
        }
        dispatch({ type: "scanStart" });
        await sleep(900);
        dispatch({ type: "log", level: "info", text: `scanner: match — ${VENDORS[m].name} download mode` });
        await sleep(700);
        if (token !== runToken.current) return;
        dispatch({ type: "scanFound", mode: m, chip: CHIP_NAMES[m as Exclude<Mode, "none">] });
      })();
    };

    const startFlash = () => {
      if (stateRef.current.source !== "sim") return;
      if (stateRef.current.job && !stateRef.current.job.finished) return;
      const scenario = SCENARIOS[stateRef.current.mode as keyof typeof SCENARIOS];
      if (!scenario) return;
      const token = ++runToken.current;
      void (async () => {
        dispatch({ type: "jobStart", title: scenario.title, total: scenario.totalBytes });
        let done = 0;
        for (const step of scenario.steps) {
          const target = done + step.share * scenario.totalBytes;
          dispatch({ type: "log", level: "info", text: `▸ ${step.label}` });
          for (const line of step.logs) {
            dispatch({ type: "log", level: "protocol", text: line });
            await sleep(240);
            if (token !== runToken.current) return;
          }
          const dt = 900 + step.share * 3200;
          const t0 = performance.now();
          for (;;) {
            const f = Math.min(1, (performance.now() - t0) / dt);
            const value = done + (target - done) * f;
            const rate = jitter(120_000_000, 60_000_000);
            dispatch({ type: "jobProgress", label: step.label, value, rate, eta: ((scenario.totalBytes - value) / rate) | 0 });
            if (f >= 1) break;
            await sleep(110);
            if (token !== runToken.current) return;
          }
          done = target;
        }
        toast(true, "Job finished", scenario.title);
        dispatch({ type: "jobEnd", failed: false });
      })();
    };

    // ---------------------------------------------------------- daemon
    const sendFlashXml = (files: string[]) =>
      sendDaemon({ cmd: "flash_xml", files, allow_missing: false });

    const startFlashReal = (plan: FlashPlan) => {
      const s = stateRef.current;
      if (s.source !== "daemon" || s.daemonGone) return;
      if (s.job && !s.job.finished) return;
      if (s.session === "needs_loader") {
        if (!plan.programmer) {
          toast(false, "Loader required", "Stage a firehose programmer first");
          return;
        }
        // Chain: upload the loader; when the session turns firehose_ready and
        // the connect job finishes, the flash_xml plan is sent automatically.
        pendingFlash.current = { files: plan.files, storage: plan.storage, skipInit: plan.skipInit };
        sendDaemon({
          cmd: "upload_loader",
          programmer: plan.programmer,
          storage: plan.storage,
          skip_storage_init: plan.skipInit,
          vip_dir: plan.vipDir ?? undefined,
        });
        return;
      }
      if (s.session === "firehose_ready") {
        pendingFlash.current = null;
        sendFlashXml(plan.files);
        return;
      }
      toast(false, "Not connected", "Connect the device first");
    };

    const connectDevice = (dev: DaemonDevice) => {
      if (stateRef.current.source !== "daemon") return;
      if (dev.mode !== "qualcomm_edl" && dev.mode !== "qualcomm_crash") {
        toast(false, "Flow pending", `${dev.label}: the TS UI covers Qualcomm for now — use the GTK app`);
        return;
      }
      sendDaemon({
        cmd: "connect",
        serial: dev.serial || undefined,
        bus: dev.bus || undefined,
        devnum: dev.devnum || undefined,
      });
    };

    const uploadLoader = (programmer: string, storage: Storage, skipInit: boolean, vipDir?: string) => {
      sendDaemon({ cmd: "upload_loader", programmer, storage, skip_storage_init: skipInit, vip_dir: vipDir ?? undefined });
    };

    const disconnectDevice = () => {
      pendingFlash.current = null;
      sendDaemon({ cmd: "disconnect" });
    };

    const resetDevice = () => {
      pendingFlash.current = null;
      sendDaemon({ cmd: "reset" });
    };

    const cancelFlash = () => {
      if (stateRef.current.source === "daemon") {
        pendingFlash.current = null;
        sendDaemon({ cmd: "cancel" });
        return;
      }
      ++runToken.current;
      dispatch({ type: "log", level: "warn", text: "job: cancelled by user — aborting transport" });
      dispatch({ type: "jobEnd", failed: true });
      toast(false, "Job cancelled", "Device left in current mode");
    };

    // Daemon event wiring (once, on mount).
    if (isTauri()) {
      dispatch({ type: "sourceSet", source: "daemon" });
      let session: SessionState = "disconnected";
      onDaemonEvent((e) => {
        switch (e.ev) {
          case "hello":
            return;
          case "log": {
            const level: Level = e.level === "debug" ? "info" : e.level;
            dispatch({ type: "log", level, text: e.text });
            return;
          }
          case "device_added":
            dispatch({ type: "devAdd", dev: e });
            return;
          case "device_removed":
            dispatch({ type: "devRemove", path: e.path });
            return;
          case "state":
            session = e.state;
            dispatch({ type: "session", session: e.state });
            return;
          case "progress": {
            const now = performance.now();
            let rate = 0;
            if (lastTick.current && now > lastTick.current.at) {
              rate = Math.max(0, (e.done - lastTick.current.done) / ((now - lastTick.current.at) / 1000));
            }
            lastTick.current = { at: now, done: e.done };
            const s = stateRef.current;
            const frac = e.total > 0 ? e.done / e.total : 0;
            const eta = rate > 0 ? Math.round((e.total - e.done) / rate) : 0;
            if (!s.job || s.job.finished) {
              dispatch({ type: "jobStart", title: "Device job", total: e.total });
            }
            dispatch({ type: "jobProgress", label: e.label, value: e.done, rate, eta });
            void frac;
            return;
          }
          case "finished": {
            lastTick.current = null;
            const chained = pendingFlash.current;
            pendingFlash.current = null;
            dispatch({ type: "jobEnd", failed: !e.success });
            toast(e.success, e.success ? "Job finished" : "Job failed", e.message);
            if (e.success && chained && session === "firehose_ready") {
              sendFlashXml(chained.files);
            }
            return;
          }
          case "chip_info": {
            const bits = [`Sahara v${e.protocol_version}`];
            if (e.hwid) bits.push(`hwid ${e.hwid}`);
            if (e.serial !== null) bits.push(`sn ${e.serial}`);
            dispatch({ type: "chipEv", chip: bits.join(" · ") });
            return;
          }
          case "partitions":
            dispatch({ type: "partsEv", lun: e.lun, sector_size: e.sector_size, luns: e.luns, vip: e.vip, rows: e.parts });
            return;
          case "huawei_app":
            return;
          case "daemon_gone":
            pendingFlash.current = null;
            dispatch({ type: "daemonGone", reason: e.reason ?? "unknown" });
            toast(false, "Backend stopped", e.reason ?? "The Zig daemon exited");
            return;
        }
      });
    }

    return {
      state,
      dispatch,
      setMode,
      startFlash,
      connectDevice,
      uploadLoader,
      disconnectDevice,
      resetDevice,
      startFlashReal,
      cancelFlash,
      toast,
    };
  }, [state]);

  return <Ctx.Provider value={api}>{children}</Ctx.Provider>;
}

export function useBus(): Api {
  const api = useContext(Ctx);
  if (!api) throw new Error("useBus outside BusProvider");
  return api;
}

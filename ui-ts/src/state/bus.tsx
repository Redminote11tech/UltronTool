/** Mock event bus. Mirrors the Zig core's event channel semantics —
 * fixed-shape events (log / progress / state-change / job-finished) drained
 * by the UI — so swapping in a real Tauri IPC backend later is a matter of
 * replacing the scenario runners with event subscriptions. */
import { createContext, useContext, useMemo, useReducer, useRef } from "react";
import type { ReactNode } from "react";
import { SCENARIOS, VENDORS } from "./vendors";
import type { Mode } from "./vendors";

export type Level = "info" | "ok" | "warn" | "error" | "protocol";
export type Page = "device" | "flash" | "console";

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

export interface State {
  page: Page;
  mode: Mode;
  scanning: boolean;
  chip: string | null;
  logs: LogLine[];
  job: Job | null;
  toasts: Toast[];
}

type Action =
  | { type: "page"; page: Page }
  | { type: "log"; level: Level; text: string }
  | { type: "clearLogs" }
  | { type: "scanStart" }
  | { type: "scanFound"; mode: Exclude<Mode, "none">; chip: string }
  | { type: "disconnect" }
  | { type: "jobStart"; title: string; total: number }
  | { type: "jobProgress"; label: string; value: number; rate: number; eta: number }
  | { type: "jobEnd"; failed: boolean }
  | { type: "toast"; toast: Toast }
  | { type: "toastGone"; id: number };

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
    { id: logId++, at: Date.now(), level: "info", text: "ultron ui — TS experiment, simulated device bus" },
  ],
  job: null,
  toasts: [],
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
      const v = VENDORS[a.mode];
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
      return s.job
        ? { ...s, job: { ...s.job, label: a.label, value: a.value, rate: a.rate, eta: a.eta } }
        : s;
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
  }
}

interface Api {
  state: State;
  dispatch: React.Dispatch<Action>;
  setMode: (m: Mode) => void;
  startFlash: () => void;
  cancelFlash: () => void;
  toast: (ok: boolean, title: string, body?: string) => void;
}

const Ctx = createContext<Api | null>(null);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const jitter = (base: number, spread: number) => base + (Math.random() - 0.5) * spread;

export function BusProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, initial);
  const runToken = useRef(0);

  const api = useMemo<Api>(() => {
    const toast = (ok: boolean, title: string, body?: string) =>
      dispatch({ type: "toast", toast: { id: ++toastId, ok, title, body } });

    const setMode = (m: Mode) => {
      void (async () => {
        const token = ++runToken.current;
        dispatch({ type: "jobEnd", failed: true });
        if (m === "none") {
          dispatch({ type: "disconnect" });
          return;
        }
        dispatch({ type: "scanStart" });
        await sleep(900);
        dispatch({ type: "log", level: "info", text: `scanner: match — ${VENDORS[m].name} download mode` });
        await sleep(700);
        if (token !== runToken.current) return;
        dispatch({ type: "scanFound", mode: m, chip: CHIP_NAMES[m] });
      })();
    };

    const startFlash = () => {
      if (state.job && !state.job.finished) return;
      const scenario = SCENARIOS[state.mode as keyof typeof SCENARIOS];
      if (!scenario) return;
      const token = ++runToken.current;
      const steps = scenario.steps;
      const total = scenario.totalBytes;

      void (async () => {
        dispatch({ type: "jobStart", title: scenario.title, total });
        let done = 0;
        for (const step of steps) {
          const target = done + step.share * total;
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
            const eta = ((total - value) / rate) | 0;
            dispatch({ type: "jobProgress", label: step.label, value, rate, eta });
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

    const cancelFlash = () => {
      ++runToken.current;
      dispatch({ type: "log", level: "warn", text: "job: cancelled by user — aborting transport" });
      dispatch({ type: "jobEnd", failed: true });
      toast(false, "Job cancelled", "Device left in current mode");
    };

    return { state, dispatch, setMode, startFlash, cancelFlash, toast };
  }, [state]);

  return <Ctx.Provider value={api}>{children}</Ctx.Provider>;
}

export function useBus(): Api {
  const api = useContext(Ctx);
  if (!api) throw new Error("useBus outside BusProvider");
  return api;
}

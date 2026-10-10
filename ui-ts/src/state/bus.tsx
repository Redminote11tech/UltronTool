/** App state bus. Two transports feed the same reducer:
 *  - daemon (real): line-JSON events from the Zig ultron-daemon via Tauri
 *  - sim (design iteration in a plain browser): scripted scenarios
 * Pages are transport-agnostic except where they check `source`. */
import { createContext, useContext, useEffect, useMemo, useReducer, useRef } from "react";
import type { ReactNode } from "react";
import { SCENARIOS, VENDORS } from "./vendors";
import type { Mode } from "./vendors";
import { progressSample } from "./progress";
import type { Sample } from "./progress";
import { JobGate, canSelectDevice } from "./jobGate";
import { programmerRequest, canReadPartition } from "./sessionPolicy";
import { isTauri } from "../lib/tauri";
import { onDaemonEvent, sendDaemon } from "./daemon";
import type { DaemonDevice } from "./daemon";

export type { Level, Page, Storage, Source, Job, LogLine, State, FlashDraft, StagedFile } from "./model";
import { createInitial, reducer, CHIP_NAMES } from "./model";
import type { State, Level, Storage, Action } from "./model";
let toastId = 0;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const jitter = (base: number, spread: number) => base + (Math.random() - 0.5) * spread;

export interface FlashPlan {
  target: { path: string; bus: number; devnum: number };
  programmer?: string;
  files: string[];
  storage: Storage;
  skipInit: boolean;
  vipDir?: string;
  reviewDigest?: string;
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
  inspectImage: (path: string) => Promise<import("./daemon").ImageInspection>;
  inspectPlan: (files: string[]) => Promise<import("./daemon").FlashInspection>;
  partitionJob: (cmd: Record<string, unknown>, target: string, lun: number, row?: {name: string; first_lba: number; last_lba: number}) => boolean;
  toast: (ok: boolean, title: string, body?: string) => void;
}

const Ctx = createContext<Api | null>(null);

export function BusProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, isTauri() ? "daemon" : "sim", createInitial);
  const stateRef = useRef(state);
  stateRef.current = state;

  const runToken = useRef(0);
  const gate = useRef(new JobGate());
  const targetLost = useRef(false);
  const inspection = useRef<{resolve: (value: import("./daemon").FlashInspection) => void; reject: (error: Error) => void; result?: import("./daemon").FlashInspection} | null>(null);
  const imageInspection = useRef<{resolve:(value:import("./daemon").ImageInspection)=>void;reject:(error:Error)=>void;result?:import("./daemon").ImageInspection} | null>(null);
  const lastTick = useRef<Sample | null>(null);

  const api = useMemo<Omit<Api, "state" | "dispatch"> & { submit: (cmd: Record<string, unknown>, title: string, target?: string | null) => boolean }>(() => {
    const toast = (ok: boolean, title: string, body?: string) =>
      dispatch({ type: "toast", toast: { id: ++toastId, ok, title, body } });

    const submit = (cmd: Record<string, unknown>, title: string, target = stateRef.current.selectedPath) => {
      const id = gate.current.begin(target);
      if (id === null) return false;
      dispatch({ type: "jobStart", title, total: 0 });
      void sendDaemon({ ...cmd, request_id: id }).catch((error: unknown) => {
        if (!gate.current.finish(id)) return;
        inspection.current?.reject(new Error(String(error)));
        inspection.current = null;
        imageInspection.current?.reject(new Error(String(error))); imageInspection.current = null;
        dispatch({ type: "jobEnd", failed: true });
        toast(false, "Command failed", String(error));
      });
      return true;
    };
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
    const startFlashReal = (plan: FlashPlan) => {
      const s = stateRef.current;
      const selected = s.devices.find(dev => dev.path === s.selectedPath);
      if (s.source !== "daemon" || s.daemonGone || s.session !== "firehose_ready" || !plan.reviewDigest) {
        toast(false, "Flash unavailable", "Load a Firehose programmer and inspect the XML plan first"); return;
      }
      if (!selected || selected.path !== plan.target.path || selected.bus !== plan.target.bus || selected.devnum !== plan.target.devnum) {
        toast(false, "Device changed", "Review the plan again"); return;
      }
      submit({cmd: "flash_xml", files: plan.files, allow_missing: false, review_digest: plan.reviewDigest}, "Flashing reviewed XML plan");
    };
    const inspectPlan = (files: string[]) => new Promise<import("./daemon").FlashInspection>((resolve, reject) => {
      if (inspection.current || gate.current.busy) { reject(new Error("Another operation is running")); return; }
      inspection.current = {resolve, reject};
      if (!submit({cmd: "preview_xml", files}, "Inspecting XML plan (read only)")) {
        inspection.current = null; reject(new Error("Could not inspect plan"));
      }
    });
    const inspectImage = (path: string) => new Promise<import("./daemon").ImageInspection>((resolve, reject) => {
      if (imageInspection.current || gate.current.busy) {reject(new Error("Another operation is running")); return;}
      imageInspection.current = {resolve, reject};
      if (!submit({cmd:"inspect_image",path}, "Inspecting image")) {imageInspection.current=null;reject(new Error("Could not inspect image"));}
    });
    const partitionJob = (cmd: Record<string, unknown>, target: string, lun: number, row?: {name: string; first_lba: number; last_lba: number}) => {
      const s = stateRef.current;
      if (!canReadPartition(s, target, lun, row)) {
        toast(false, "Device or partition table changed", "Read the table again before continuing"); return false;
      }
      return submit({...cmd, lun}, cmd.cmd === "write_partition" ? `Writing ${cmd.label}` : cmd.cmd === "read_partition" ? `Backing up ${cmd.label}` : "Reading partition table");
    };

    const connectDevice = (dev: DaemonDevice) => {
      if (stateRef.current.source !== "daemon") return;
      if (dev.mode !== "qualcomm_edl" && dev.mode !== "qualcomm_crash") {
        toast(false, "Flow pending", `${dev.label}: the TS UI covers Qualcomm for now — use the GTK app`);
        return;
      }
      if (!canSelectDevice(stateRef.current.selectedPath, dev.path, stateRef.current.session, gate.current.busy)) return;
      dispatch({ type: "devSelect", path: dev.path });
      targetLost.current = false;
      submit({
        cmd: "connect",
        target_path: dev.path,
        storage: stateRef.current.draft.storage,
        skip_storage_init: stateRef.current.draft.skipInit,
        vip_dir: stateRef.current.draft.files.vip?.paths[0],
        bus: dev.bus || undefined,
        devnum: dev.devnum || undefined,
      }, "Connecting device", dev.path);
    };

    const uploadLoader = (programmer: string, storage: Storage, skipInit: boolean, vipDir?: string) => {
      if (gate.current.busy) return;
      const request = programmerRequest(stateRef.current, programmer, storage, skipInit, vipDir);
      if (!request) return;
      targetLost.current = false;
      submit(request, request.cmd === "connect" ? "Connecting and loading programmer" : "Uploading programmer");
    };

    const disconnectDevice = () => {
      submit({ cmd: "disconnect" }, "Disconnecting");
    };

    const resetDevice = () => {
      if (!stateRef.current.selectedPath || stateRef.current.session !== "firehose_ready") return;
      submit({ cmd: "reset" }, "Resetting device");
    };

    const cancelFlash = () => {
      if (stateRef.current.source === "daemon") {
        void sendDaemon({ cmd: "cancel" }).catch(error => toast(false, "Cancel failed", String(error)));
        return;
      }
      ++runToken.current;
      dispatch({ type: "log", level: "warn", text: "job: cancelled by user — aborting transport" });
      dispatch({ type: "jobEnd", failed: true });
      toast(false, "Job cancelled", "Device left in current mode");
    };

    // Daemon event wiring lives in a mount-once useEffect below — dispatching
    // from a state-keyed memo here caused an infinite re-render loop that
    // crashed React (the "garbled window" bug).

    return {
      setMode,
      startFlash,
      connectDevice,
      uploadLoader,
      disconnectDevice,
      resetDevice,
      startFlashReal,
      inspectPlan,
      inspectImage,
      partitionJob,
      cancelFlash,
      toast,
      submit,
    };
  }, []);

  // Real daemon transport (mount-once): one subscription for the app's
  // lifetime. A `.finished` closes a job and consumes the cancel flag,
  // exactly like the GTK UI's jobDone().
  useEffect(() => {
    if (!isTauri()) return;

    return onDaemonEvent((e) => {
      switch (e.ev) {
        case "image_info":
          if (imageInspection.current) imageInspection.current.result = e;
          return;
        case "flash_plan":
          if (inspection.current) inspection.current.result = e;
          return;
        case "hello":
          dispatch({ type: "sourceSet", source: "daemon", protocolVersion: e.version });
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
          if (e.path === gate.current.target) {
            targetLost.current = true;
            if (gate.current.busy) void sendDaemon({ cmd: "cancel" }).catch(error => api.toast(false, "Cancel failed", String(error)));
            // The daemon invalidates an idle session independently of the webview.
          }
          dispatch({ type: "devRemove", path: e.path });
          return;
        case "session_target":
          gate.current.target = e.path;
          dispatch({ type: "sessionTarget", path: e.path });
          return;
        case "request_active":
          gate.current.restore(e.request_id, gate.current.target);
          dispatch({ type: "jobStart", title: "Device operation", total: 0 });
          return;
        case "session_config":
          dispatch({ type: "configured", storage: e.storage as Storage, skipInit: e.skip_init, vipDir: e.vip_dir });
          return;
        case "state":
          if (targetLost.current && e.state !== "disconnected") return;
          dispatch({ type: "session", session: e.state });
          return;
        case "progress": {
          const now = performance.now();
          const progress = progressSample(lastTick.current, e, now);
          lastTick.current = progress.sample;
          const s = stateRef.current;
          if (!s.job || s.job.finished) {
            dispatch({ type: "jobStart", title: "Device job", total: e.total });
          }
          dispatch({ type: "jobProgress", label: e.label, value: e.done, total: e.total, fraction: progress.fraction, rate: progress.rate, eta: progress.eta });
          return;
        }
        case "finished": {
          if (!gate.current.finish(e.request_id ?? -1)) return;
          lastTick.current = null;
          dispatch({ type: "jobEnd", failed: !e.success, message: e.message });
          api.toast(e.success, e.success ? "Job finished" : "Job failed", e.message);
          if (inspection.current) {
            const pending = inspection.current; inspection.current = null;
            if (e.success && pending.result) pending.resolve(pending.result); else pending.reject(new Error(e.message || "Plan inspection failed"));
          }
          if (imageInspection.current) {
            const pending=imageInspection.current; imageInspection.current=null;
            if(e.success && pending.result) pending.resolve(pending.result); else pending.reject(new Error(e.message || "Image inspection failed"));
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
          if (targetLost.current) return;
          dispatch({ type: "partsEv", lun: e.lun, sector_size: e.sector_size, luns: e.luns, vip: e.vip, rows: e.parts });
          return;
        case "huawei_app":
          return;
        case "daemon_gone":
          imageInspection.current?.reject(new Error(e.reason || "Backend stopped")); imageInspection.current=null;
          inspection.current?.reject(new Error(e.reason || "Backend stopped")); inspection.current = null;
          if (gate.current.active !== null) gate.current.finish(gate.current.active);
          dispatch({ type: "daemonGone", reason: e.reason ?? "unknown" });
          api.toast(false, "Backend stopped", e.reason ?? "The Zig daemon exited");
          return;
      }
    });
  }, []);

  const value: Api = { ...api, state, dispatch };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useBus(): Api {
  const api = useContext(Ctx);
  if (!api) throw new Error("useBus outside BusProvider");
  return api;
}

import { motion, AnimatePresence } from "motion/react";
import { FileText, Lock, Loader2, X, Zap, ShieldAlert, FolderOpen } from "lucide-react";
import { useState } from "react";
import { useBus } from "../state/bus";
import type { Storage } from "../state/bus";
import { SLOTS, VENDORS } from "../state/vendors";
import type { SlotCfg } from "../state/vendors";
import { pickFiles } from "../lib/tauri";
import { Button, HoldButton } from "../components/Button";
import { SwitchRow } from "../components/Switch";
import { Progress } from "../components/Progress";
import { bytes, eta, rate } from "../lib/format";
import { item, stagger } from "../lib/motion";

interface Filled {
  name: string;
  size: number;
  /** real filesystem paths (daemon); empty in sim */
  paths: string[];
}

const QUALCOMM_SLOTS: SlotCfg[] = [
  { id: "programmer", label: "Firehose programmer", hint: ".mbn / .elf — vendor-signed, user-supplied", required: true, fake: "firehose.mbn", fakeSize: 3_210_000 },
  { id: "rawprogram", label: "rawprogram XML", hint: "rawprogram*.xml — flash plan", required: true, fake: "rawprogram0.xml", fakeSize: 84_000 },
  { id: "patch", label: "patch XML", hint: "patch*.xml — partition table patches", required: false, fake: "patch0.xml", fakeSize: 12_000 },
  { id: "vip", label: "VIP digest tables", hint: "folder with DigestsToSign.bin.mbn — only for programmers enforcing VIP", required: false, fake: "DigestsToSign", fakeSize: 0 },
];

const MBN_FILTERS = [{ name: "Firehose programmer", extensions: ["mbn", "elf", "bin"] }];
const XML_FILTERS = [{ name: "rawprogram / patch XML", extensions: ["xml"] }];

export function FlashPage() {
  const { state, startFlash, cancelFlash, startFlashReal } = useBus();
  const [files, setFiles] = useState<Record<string, Filled | null>>({});
  const [attaching, setAttaching] = useState<string | null>(null);
  const [erase, setErase] = useState(false);
  const [verify, setVerify] = useState(true);
  const [reboot, setReboot] = useState(true);
  const [storage, setStorage] = useState<Storage>("ufs");
  const [skipInit, setSkipInit] = useState(false);

  const daemon = state.source === "daemon";
  const mode = state.mode === "none" ? null : state.mode;
  const slots: SlotCfg[] = daemon ? QUALCOMM_SLOTS : mode ? SLOTS[mode] : [];
  const job = state.job;
  const running = job !== null && !job.finished;
  const destructive = !daemon && erase;

  const selectedDev = daemon ? state.devices.find((d) => d.path === state.selectedPath) ?? null : null;
  const session = state.session;

  const requiredMissing = slots.some((s) => {
    if (!s.required || s.disabledNote) return false;
    if (s.id === "programmer" && daemon && session === "firehose_ready") return false; // programmer already lives on the device
    return !files[s.id];
  });
  const canStart = daemon
    ? selectedDev !== null &&
      !requiredMissing &&
      !running &&
      !state.daemonGone &&
      (session === "firehose_ready" || (session === "needs_loader" && !!files["programmer"]))
    : mode !== null && !requiredMissing && !running;

  const simFill = (s: SlotCfg) => {
    if (s.disabledNote || files[s.id] || attaching) return;
    setAttaching(s.id);
    window.setTimeout(() => {
      setFiles((f) => ({ ...f, [s.id]: { name: s.fake, size: s.fakeSize, paths: [] } }));
      setAttaching(null);
    }, 380);
  };

  const daemonPick = async (s: SlotCfg) => {
    if (s.id === "vip") {
      const dirs = await pickFiles({ directory: true, title: "VIP digest tables folder" });
      if (dirs.length === 0) return;
      setFiles((f) => ({ ...f, vip: { name: dirs[0].split("/").pop() ?? dirs[0], size: 0, paths: [dirs[0]] } }));
      return;
    }
    const filters = s.id === "programmer" ? MBN_FILTERS : XML_FILTERS;
    const paths = await pickFiles({ multiple: s.id !== "programmer", filters, title: s.label });
    if (paths.length === 0) return;
    setFiles((f) => ({
      ...f,
      [s.id]: {
        name: paths.length === 1 ? (paths[0].split("/").pop() ?? paths[0]) : `${paths[0].split("/").pop()} +${paths.length - 1}`,
        size: 0,
        paths,
      },
    }));
  };

  const pick = (s: SlotCfg) => {
    if (s.disabledNote || files[s.id] || attaching) return;
    if (daemon) void daemonPick(s);
    else simFill(s);
  };

  const clear = (id: string) => (e: React.MouseEvent) => {
    e.stopPropagation();
    setFiles((f) => ({ ...f, [id]: null }));
  };

  const onStart = () => {
    if (daemon) {
      startFlashReal({
        programmer: files["programmer"]?.paths[0],
        files: [...(files["rawprogram"]?.paths ?? []), ...(files["patch"]?.paths ?? [])],
        storage,
        skipInit,
        vipDir: files["vip"]?.paths[0],
      });
      return;
    }
    startFlash();
  };

  const fileCount = Object.values(files).filter(Boolean).length;

  if (!daemon && !mode) {
    return (
      <div className="page" style={{ display: "grid", placeItems: "center", minHeight: "60vh" }}>
        <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} style={{ textAlign: "center", color: "var(--text-2)" }}>
          <div className="m3-empty-icon" style={{ marginBottom: 16 }}>
            <Zap size={36} strokeWidth={1.6} />
          </div>
          <p>No device — connect one on the Device page to unlock flashing.</p>
        </motion.div>
      </div>
    );
  }

  if (daemon && !selectedDev) {
    return (
      <div className="page" style={{ display: "grid", placeItems: "center", minHeight: "60vh" }}>
        <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} style={{ textAlign: "center", color: "var(--text-2)" }}>
          <div className="m3-empty-icon" style={{ marginBottom: 16 }}>
            <Zap size={36} strokeWidth={1.6} />
          </div>
          <p>{state.devices.length === 0 ? "No device on the bus — connect one first." : "Select a device on the Device page first."}</p>
        </motion.div>
      </div>
    );
  }

  const v = daemon ? VENDORS[(selectedDev?.mode ?? "qualcomm_edl") as keyof typeof VENDORS] : VENDORS[mode!];
  const sessionNote = daemon
    ? session === "needs_loader"
      ? "Device waits for a firehose programmer — Start uploads it, then flashes."
      : session === "firehose_ready"
        ? "Firehose session is live — Start flashes the staged rawprogram/patch plan."
        : "Connect the device on the Device page first."
    : `Simulated ${v.name} session`;

  return (
    <div className="page">
      <AnimatePresence mode="wait">
        {running && job && (
          <motion.div
            key="job"
            className="card pad"
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.25, ease: [0.05, 0.7, 0.1, 1] }}
            style={{ marginBottom: 20 }}
          >
            {job.finished && !job.failed && (
              <motion.div className="banner-ok" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
                ✔ {job.label || "Job finished"}
              </motion.div>
            )}
            {job.finished && job.failed && (
              <motion.div className="banner-err" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
                ⚠ {job.label || "Job failed"}
              </motion.div>
            )}
            {!job.finished && (
              <>
                <Progress value={job.value} total={job.total} />
                <div className="prog-meta">
                  <span className="prog-pct mono">{job.total > 0 ? `${((job.value / job.total) * 100).toFixed(1)}%` : "—"}</span>
                  {job.total > 0 && <span className="mono">{bytes(job.value)} / {bytes(job.total)}</span>}
                  {job.rate > 0 && <span className="mono">{rate(job.rate)}</span>}
                  <span style={{ marginLeft: "auto" }} className="mono">{job.eta > 0 ? `ETA ${eta(job.eta)}` : ""}</span>
                  <Button variant="text" onClick={cancelFlash}>Cancel</Button>
                </div>
                <div className="prog-label">{job.label}</div>
              </>
            )}
          </motion.div>
        )}
      </AnimatePresence>

      <div className="flash-grid">
        <motion.div key={daemon ? "daemon" : mode} variants={stagger} initial="initial" animate="animate">
          <div className="flash-head">
            <span className="dot" style={{ background: v.color }} />
            <b>{v.name} flash plan</b>
            <span className="note">
              {daemon ? `${selectedDev?.label} · ${session.replace("_", " ")}` : `slot layout mirrors the ${v.name} module's real inputs`}
            </span>
          </div>

          {slots.map((s) => {
            const f = files[s.id];
            return (
              <motion.div
                key={s.id}
                variants={item}
                className={`slot ${f ? "filled" : ""} ${s.disabledNote ? "disabled" : ""}`}
                onClick={() => pick(s)}
              >
                <div className="slot-title">
                  {s.disabledNote ? <Lock size={16} /> : <FileText size={16} color={f ? "var(--accent)" : undefined} />}
                  {s.label}
                  <span className={`req ${s.required ? "yes" : "opt"}`}>
                    {s.disabledNote ? "SOON" : s.required ? "REQUIRED" : "OPTIONAL"}
                  </span>
                </div>
                <p className="slot-hint">{s.disabledNote ?? s.hint}</p>

                {attaching === s.id && (
                  <div className="slot-file"><Loader2 size={14} className="spin" /> reading…</div>
                )}
                {f && (
                  <motion.div className="slot-file" initial={{ opacity: 0, x: -6 }} animate={{ opacity: 1, x: 0 }} transition={{ duration: 0.2, ease: [0.2, 0, 0, 1] }}>
                    {s.id === "vip" && <FolderOpen size={14} />}
                    <span className="mono">{f.name}</span>
                    {f.size > 0 && <span className="size mono">{bytes(f.size)}</span>}
                    <button className="slot-x" onClick={clear(s.id)} aria-label="remove">
                      <X size={14} />
                    </button>
                  </motion.div>
                )}
              </motion.div>
            );
          })}
        </motion.div>

        <motion.div className="card pad" variants={stagger} initial="initial" animate="animate" style={{ position: "sticky", top: 28 }}>
          {daemon ? (
            <motion.div variants={item}>
              <div className="switch-row" style={{ borderTop: 0 }}>
                <div className="switch-label">
                  <b>Storage</b>
                  <span>firehose MemoryName — set at configure time</span>
                </div>
                <select className="select" value={storage} onChange={(e) => setStorage(e.target.value as Storage)} style={{ height: 36 }}>
                  <option value="ufs">UFS</option>
                  <option value="emmc">eMMC</option>
                  <option value="spinor">SPI NOR</option>
                  <option value="nand">NAND</option>
                  <option value="nvme">NVMe</option>
                </select>
              </div>
              <SwitchRow
                title="Skip storage init"
                note="SkipStorageInit — for programmers that refuse init"
                on={skipInit}
                onChange={setSkipInit}
              />
            </motion.div>
          ) : (
            <motion.div variants={item}>
              <SwitchRow title="Erase user data" note="Destructive — hold-to-confirm on start" on={erase} onChange={setErase} danger />
              <SwitchRow title="Verify digests" note="VIP table / md5 checks during write" on={verify} onChange={setVerify} />
              <SwitchRow title="Reboot after flash" note="Send protocol reset on success" on={reboot} onChange={setReboot} />
            </motion.div>
          )}

          <motion.div variants={item} style={{ marginTop: 14 }}>
            <div className="summary-row"><span>Files staged</span><span className="v mono">{fileCount}</span></div>
            <div className="summary-row">
              <span>Session</span>
              <span className="v" style={{ color: session === "firehose_ready" ? "var(--ok)" : session === "needs_loader" ? "var(--warn)" : "var(--text-2)" }}>
                {daemon ? session.replace("_", " ") : "simulated"}
              </span>
            </div>
            {state.parts && (
              <div className="summary-row">
                <span>Partitions</span>
                <span className="v mono">{state.parts.rows.length} · {state.parts.sector_size} B</span>
              </div>
            )}
          </motion.div>

          <motion.div variants={item} style={{ marginTop: 20 }}>
            {destructive ? (
              <HoldButton
                disabled={requiredMissing || running}
                onConfirm={onStart}
                label={<><ShieldAlert size={16} /> Hold to erase + flash</>}
                holdingLabel="Keep holding…"
              />
            ) : (
              <Button variant="filled" large block disabled={!canStart} onClick={onStart}>
                <Zap size={16} /> Start flash
              </Button>
            )}
            <p style={{ fontSize: 12, color: "var(--text-2)", textAlign: "center", margin: "12px 0 0" }}>
              {daemon
                ? sessionNote
                : requiredMissing
                  ? "Stage the required files to enable start"
                  : destructive
                    ? "Destructive op — press and hold"
                    : `Simulated ${v.name} session`}
            </p>
          </motion.div>
        </motion.div>
      </div>
    </div>
  );
}

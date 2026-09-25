import { motion, AnimatePresence } from "motion/react";
import { FileText, Lock, Loader2, X, Zap, ShieldAlert } from "lucide-react";
import { useState } from "react";
import { useBus } from "../state/bus";
import { SLOTS, VENDORS } from "../state/vendors";
import type { SlotCfg } from "../state/vendors";
import { Button, HoldButton } from "../components/Button";
import { SwitchRow } from "../components/Switch";
import { Progress } from "../components/Progress";
import { bytes, eta, rate } from "../lib/format";
import { item, stagger } from "../lib/motion";

interface Filled {
  name: string;
  size: number;
}

export function FlashPage() {
  const { state, startFlash, cancelFlash } = useBus();
  const [files, setFiles] = useState<Record<string, Filled | null>>({});
  const [attaching, setAttaching] = useState<string | null>(null);
  const [erase, setErase] = useState(false);
  const [verify, setVerify] = useState(true);
  const [reboot, setReboot] = useState(true);

  const mode = state.mode === "none" ? null : state.mode;
  const slots: SlotCfg[] = mode ? SLOTS[mode] : [];
  const requiredMissing = slots.some((s) => s.required && !s.disabledNote && !files[s.id]);
  const job = state.job;
  const running = job !== null && !job.finished;
  const destructive = erase;

  const fill = (s: SlotCfg) => {
    if (s.disabledNote || files[s.id] || attaching) return;
    setAttaching(s.id);
    window.setTimeout(() => {
      setFiles((f) => ({ ...f, [s.id]: { name: s.fake, size: s.fakeSize } }));
      setAttaching(null);
    }, 380);
  };

  const clear = (id: string) => (e: React.MouseEvent) => {
    e.stopPropagation();
    setFiles((f) => ({ ...f, [id]: null }));
  };

  const totalSize = Object.values(files).reduce((a, f) => a + (f?.size ?? 0), 0);
  const fileCount = Object.values(files).filter(Boolean).length;

  if (!mode) {
    return (
      <div className="page" style={{ display: "grid", placeItems: "center", minHeight: "60vh" }}>
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          style={{ textAlign: "center", color: "var(--text-2)" }}
        >
          <div className="m3-empty-icon" style={{ marginBottom: 16 }}>
            <Zap size={36} strokeWidth={1.6} />
          </div>
          <p>No device — connect one on the Device page to unlock flashing.</p>
        </motion.div>
      </div>
    );
  }

  const v = VENDORS[mode];

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
                ✔ Job finished — device rebooted.
              </motion.div>
            )}
            {job.finished && job.failed && (
              <motion.div className="banner-err" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
                ⚠ Job cancelled — session torn down.
              </motion.div>
            )}
            <Progress value={job.value} total={job.total} />
            <div className="prog-meta">
              <span className="prog-pct mono">{((job.value / job.total) * 100).toFixed(1)}%</span>
              <span className="mono">{bytes(job.value)} / {bytes(job.total)}</span>
              <span className="mono">{rate(job.rate)}</span>
              <span style={{ marginLeft: "auto" }} className="mono">ETA {eta(job.eta)}</span>
              {!job.finished && (
                <Button variant="text" onClick={cancelFlash}>Cancel</Button>
              )}
            </div>
            <div className="prog-label">{job.label}</div>
          </motion.div>
        )}
      </AnimatePresence>

      <div className="flash-grid">
        <motion.div
          key={mode}
          variants={stagger}
          initial="initial"
          animate="animate"
        >
          <div className="flash-head">
            <span className="dot" style={{ background: v.color }} />
            <b>{v.name} flash plan</b>
            <span className="note">slot layout mirrors the {v.name} module's real inputs</span>
          </div>

          {slots.map((s) => {
            const f = files[s.id];
            return (
              <motion.div
                key={s.id}
                variants={item}
                className={`slot ${f ? "filled" : ""} ${s.disabledNote ? "disabled" : ""}`}
                onClick={() => fill(s)}
              >
                <div className="slot-title">
                  {s.disabledNote ? <Lock size={16} /> : f ? <FileText size={16} color="var(--accent)" /> : <FileText size={16} />}
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
                  <motion.div
                    className="slot-file"
                    initial={{ opacity: 0, x: -6 }}
                    animate={{ opacity: 1, x: 0 }}
                    transition={{ duration: 0.2, ease: [0.2, 0, 0, 1] }}
                  >
                    <span className="mono">{f.name}</span>
                    <span className="size mono">{bytes(f.size)}</span>
                    <button className="slot-x" onClick={clear(s.id)} aria-label="remove">
                      <X size={14} />
                    </button>
                  </motion.div>
                )}
              </motion.div>
            );
          })}
        </motion.div>

        <motion.div
          className="card pad"
          variants={stagger}
          initial="initial"
          animate="animate"
          style={{ position: "sticky", top: 28 }}
        >
          <motion.div variants={item}>
            <SwitchRow
              title="Erase user data"
              note="Destructive — hold-to-confirm on start"
              on={erase}
              onChange={setErase}
              danger
            />
            <SwitchRow
              title="Verify digests"
              note="VIP table / md5 checks during write"
              on={verify}
              onChange={setVerify}
            />
            <SwitchRow
              title="Reboot after flash"
              note="Send protocol reset on success"
              on={reboot}
              onChange={setReboot}
            />
          </motion.div>

          <motion.div variants={item} style={{ marginTop: 14 }}>
            <div className="summary-row"><span>Files staged</span><span className="v mono">{fileCount}</span></div>
            <div className="summary-row"><span>Total payload</span><span className="v mono">{bytes(totalSize)}</span></div>
            <div className="summary-row">
              <span>Digest checks</span>
              <span className="v" style={{ color: verify ? "var(--ok)" : "var(--warn)" }}>
                {verify ? "on" : "off"}
              </span>
            </div>
          </motion.div>

          <motion.div variants={item} style={{ marginTop: 20 }}>
            {destructive ? (
              <HoldButton
                disabled={requiredMissing || running}
                onConfirm={startFlash}
                label={<><ShieldAlert size={16} /> Hold to erase + flash</>}
                holdingLabel="Keep holding…"
              />
            ) : (
              <Button
                variant="filled"
                large
                block
                disabled={requiredMissing || running}
                onClick={startFlash}
              >
                <Zap size={16} /> Start flash
              </Button>
            )}
            <p style={{ fontSize: 12, color: "var(--text-2)", textAlign: "center", margin: "12px 0 0" }}>
              {requiredMissing
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

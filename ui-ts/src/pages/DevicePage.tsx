import { motion, AnimatePresence } from "motion/react";
import { Cpu, RefreshCw, Power, ArrowRight, Radio, Check } from "lucide-react";
import { useBus } from "../state/bus";
import { VENDORS } from "../state/vendors";
import type { Mode } from "../state/vendors";
import { Button } from "../components/Button";
import { Modal } from "../components/Modal";
import { IndeterminateProgress } from "../components/Progress";
import { useState } from "react";
import { item, stagger } from "../lib/motion";

export function DevicePage() {
  const { state, dispatch, setMode, toast } = useBus();
  const [confirmReset, setConfirmReset] = useState(false);
  const v = state.mode !== "none" ? VENDORS[state.mode] : null;

  return (
    <div className="page">
      <div className="device-hero">
        <motion.div
          className="card pad device-card"
          variants={item}
          initial="initial"
          animate="animate"
          key={state.mode === "none" ? "empty" : state.mode}
        >
          <AnimatePresence mode="wait">
            {v ? (
              <motion.div
                key="found"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.2, ease: [0.05, 0.7, 0.1, 1] }}
              >
                <div
                  className="m3-empty-icon"
                  style={{
                    background: `color-mix(in srgb, ${v.color} 16%, transparent)`,
                    color: v.color,
                  }}
                >
                  <Cpu size={40} strokeWidth={1.6} />
                </div>

                <h2>{v.name} · {v.modeLabel}</h2>
                <p className="sub">Connected over USB. Ready for {v.name} protocol operations.</p>

                <div className="kv mono"><span className="k">Chip</span><span>{state.chip}</span></div>
                <div className="kv mono"><span className="k">Transport</span><span>bulk pair · 512 B</span></div>
                <div className="kv mono"><span className="k">Link state</span><span style={{ color: "var(--ok)" }}>● session open</span></div>

                <div className="device-actions">
                  <Button variant="filled" onClick={() => dispatch({ type: "page", page: "flash" })}>
                    Open Flash <ArrowRight size={15} />
                  </Button>
                  <Button variant="outlined" onClick={() => setConfirmReset(true)}>
                    <Power size={14} /> Reset device
                  </Button>
                  <Button variant="text" onClick={() => setMode("none")}>
                    <RefreshCw size={13} /> Disconnect
                  </Button>
                </div>
              </motion.div>
            ) : (
              <motion.div
                key="empty"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.15 }}
              >
                <div className="m3-empty-icon">
                  <motion.span
                    animate={{ opacity: state.scanning ? [0.5, 1, 0.5] : 1 }}
                    transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
                    style={{ display: "grid", placeItems: "center" }}
                  >
                    <Radio size={40} strokeWidth={1.6} />
                  </motion.span>
                </div>
                <h2>{state.scanning ? "Searching for devices…" : "No device connected"}</h2>
                <p className="sub">
                  Plug the device in and enter its download mode. Ultron listens for
                  hotplug events and classifies the port automatically.
                </p>
                {state.scanning && (
                  <div className="scan-progress"><IndeterminateProgress /></div>
                )}
              </motion.div>
            )}
          </AnimatePresence>
        </motion.div>
      </div>

      <motion.div
        className="vendor-strip"
        variants={stagger}
        initial="initial"
        animate="animate"
      >
        {(Object.keys(VENDORS) as Exclude<Mode, "none">[]).map((id) => {
          const meta = VENDORS[id];
          const active = state.mode === id;
          return (
            <motion.button
              key={id}
              className={`vendor-chip ${active ? "active" : ""}`}
              variants={item}
              onClick={() => setMode(id)}
              title={`Simulate a ${meta.name} device (design-review switch)`}
            >
              <span className="dot" style={{ background: meta.color }} />
              {meta.name}
              <span style={{ opacity: 0.7 }}>· {meta.modeLabel}</span>
              {active && <Check size={14} />}
            </motion.button>
          );
        })}
      </motion.div>

      <Modal open={confirmReset}>
        <h3>Reset the device?</h3>
        <p>
          A protocol reset reboots the device out of download mode. Unsaved flash
          state is discarded. This is safe but the session closes.
        </p>
        <div className="modal-actions">
          <Button variant="text" onClick={() => setConfirmReset(false)}>Cancel</Button>
          <Button
            variant="filled"
            onClick={() => {
              setConfirmReset(false);
              dispatch({ type: "log", level: "info", text: "reset: device rebooted (sim)" });
              toast(true, "Device reset", "Rebooting out of download mode");
              setMode("none");
            }}
          >
            Reset
          </Button>
        </div>
      </Modal>
    </div>
  );
}

import { motion, AnimatePresence } from "motion/react";
import { Cpu, RefreshCw, Power, ArrowRight, Radio } from "lucide-react";
import { useBus } from "../state/bus";
import { VENDORS } from "../state/vendors";
import type { Mode } from "../state/vendors";
import { Button } from "../components/Button";
import { Modal } from "../components/Modal";
import { useState } from "react";
import { springGentle, springSnappy, item, stagger } from "../lib/motion";

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
                initial={{ opacity: 0, scale: 0.96, y: 10 }}
                animate={{ opacity: 1, scale: 1, y: 0 }}
                exit={{ opacity: 0, scale: 0.98, y: -8 }}
                transition={springGentle}
              >
                <motion.div
                  style={{
                    width: 56, height: 56, borderRadius: 16, margin: "0 auto 16px",
                    background: `color-mix(in srgb, ${v.color} 14%, transparent)`,
                    boxShadow: `inset 0 0 0 1px color-mix(in srgb, ${v.color} 45%, transparent)`,
                    display: "grid", placeItems: "center", color: v.color,
                  }}
                  initial={{ rotate: -8, scale: 0.8 }}
                  animate={{ rotate: 0, scale: 1 }}
                  transition={springSnappy}
                >
                  <Cpu size={26} />
                </motion.div>

                <h2>{v.name} · {v.modeLabel}</h2>
                <p className="sub">Connected over USB. Ready for {v.name} protocol operations.</p>

                <div className="kv mono"><span className="k">Chip</span><span>{state.chip}</span></div>
                <div className="kv mono"><span className="k">Transport</span><span>bulk pair · 512 B</span></div>
                <div className="kv mono"><span className="k">Link state</span><span style={{ color: "var(--ok)" }}>● session open</span></div>

                <div className="device-actions">
                  <Button variant="primary" onClick={() => dispatch({ type: "page", page: "flash" })}>
                    Open Flash <ArrowRight size={15} />
                  </Button>
                  <Button variant="ghost" onClick={() => setConfirmReset(true)}>
                    <Power size={14} /> Reset device
                  </Button>
                  <Button variant="ghost" onClick={() => setMode("none")}>
                    <RefreshCw size={13} /> Disconnect
                  </Button>
                </div>
              </motion.div>
            ) : (
              <motion.div
                key="empty"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ duration: 0.18 }}
              >
                <div className="radar">
                  <span className="radar-ring" />
                  <span className="radar-ring" />
                  <span className="radar-ring" />
                  <span className="radar-core">
                    <motion.span
                      animate={{ opacity: [0.45, 1, 0.45] }}
                      transition={{ duration: 2, repeat: Infinity }}
                      style={{ display: "grid", placeItems: "center" }}
                    >
                      <Radio size={22} />
                    </motion.span>
                  </span>
                </div>
                <h2>{state.scanning ? "Searching for devices…" : "No device connected"}</h2>
                <p className="sub">
                  Plug the device in and enter its download mode. Ultron listens for
                  hotplug events and classifies the port automatically.
                </p>
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
              whileHover={{ y: -2 }}
              whileTap={{ scale: 0.96 }}
              transition={springSnappy}
              onClick={() => setMode(id)}
              style={
                active
                  ? { boxShadow: `inset 0 0 0 1px color-mix(in srgb, ${meta.color} 55%, transparent), 0 0 22px color-mix(in srgb, ${meta.color} 18%, transparent)` }
                  : undefined
              }
              title={`Simulate a ${meta.name} device (design-review switch)`}
            >
              <span
                className="dot"
                style={{ background: meta.color, animation: active ? "pulse 1.8s ease-in-out infinite" : undefined }}
              />
              {meta.name}
              <span style={{ color: "var(--text-3)" }}>· {meta.modeLabel}</span>
            </motion.button>
          );
        })}
      </motion.div>

      <Modal open={confirmReset}>
        <h3>
          <Power size={16} color="var(--warn)" /> Reset the device?
        </h3>
        <p>
          A protocol reset reboots the device out of download mode. Unsaved flash
          state is discarded. This is safe but the session closes.
        </p>
        <div className="modal-actions">
          <Button variant="ghost" onClick={() => setConfirmReset(false)}>Cancel</Button>
          <Button
            variant="primary"
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

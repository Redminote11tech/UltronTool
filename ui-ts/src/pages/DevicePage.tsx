import { motion, AnimatePresence } from "motion/react";
import { Cpu, RefreshCw, Power, ArrowRight, Radio, Check, PlugZap, TriangleAlert } from "lucide-react";
import { useBus } from "../state/bus";
import { VENDORS } from "../state/vendors";
import type { Mode } from "../state/vendors";
import type { DaemonDevice } from "../state/daemon";
import { Button } from "../components/Button";
import { Modal } from "../components/Modal";
import { useState } from "react";
import { item, stagger } from "../lib/motion";

const SESSION_TEXT: Record<string, { label: string; color: string }> = {
  disconnected: { label: "no session", color: "var(--text-3)" },
  needs_loader: { label: "loader required", color: "var(--warn)" },
  firehose_ready: { label: "firehose ready", color: "var(--ok)" },
  samsung_ready: { label: "odin ready", color: "var(--ok)" },
  lg_ready: { label: "laf ready", color: "var(--ok)" },
  spd_ready: { label: "fdl2 ready", color: "var(--ok)" },
};

function hex(n: number): string {
  return n.toString(16).padStart(4, "0");
}

interface CardActions {
  onConnect: () => void;
  onOpenFlash: () => void;
  onReset: () => void;
  onDisconnect: () => void;
}

function DeviceCard({
  dev,
  selected,
  onSelect,
  busy,
  session,
  actions,
}: {
  dev: DaemonDevice;
  selected: boolean;
  onSelect: () => void;
  busy: boolean;
  session: string;
  actions: CardActions;
}) {
  const meta = VENDORS[dev.mode as keyof typeof VENDORS];
  const supported = dev.mode === "qualcomm_edl" || dev.mode === "qualcomm_crash";

  return (
    <motion.button
      className="card pad"
      variants={item}
      onClick={onSelect}
      style={{
        width: "100%", textAlign: "left", cursor: "pointer", border: 0, display: "block",
        boxShadow: selected
          ? "inset 0 0 0 2px var(--md-primary)"
          : "inset 0 0 0 1px var(--md-outline-variant)",
        transition: "box-shadow 200ms cubic-bezier(0.2, 0, 0, 1)",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <span
          style={{
            width: 44, height: 44, borderRadius: 12, flex: "none",
            background: `color-mix(in srgb, ${meta?.color ?? "var(--text-3)"} 14%, transparent)`,
            color: meta?.color ?? "var(--text-3)",
            display: "grid", placeItems: "center",
          }}
        >
          <Cpu size={22} />
        </span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <b style={{ fontSize: 15 }}>{dev.label}</b>
          <div className="mono" style={{ fontSize: 12.5, color: "var(--text-2)" }}>
            {hex(dev.vid)}:{hex(dev.pid)}
            {dev.serial ? ` · sn ${dev.serial}` : ""}
            {dev.product ? ` · ${dev.product}` : ""}
          </div>
        </div>
        {!supported && <span className="req opt">TS FLOW PENDING</span>}
        {selected && supported && <Check size={16} color="var(--accent)" />}
      </div>

      {selected && supported && (
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 16, flexWrap: "wrap" }}>
          <span className="pill">
            <span
              className={`dot ${session !== "disconnected" ? "live" : ""}`}
              style={{ background: SESSION_TEXT[session]?.color }}
            />
            {SESSION_TEXT[session]?.label ?? session}
          </span>
          {session === "disconnected" && (
            <Button variant="filled" disabled={busy} onClick={actions.onConnect}>
              <PlugZap size={15} /> Connect
            </Button>
          )}
          {session === "needs_loader" && (
            <Button variant="tonal" onClick={actions.onOpenFlash}>
              Continue on Flash page <ArrowRight size={14} />
            </Button>
          )}
          {session === "firehose_ready" && (
            <Button variant="outlined" onClick={actions.onOpenFlash}>
              Open Flash <ArrowRight size={14} />
            </Button>
          )}
          {session !== "disconnected" && (
            <Button variant="text" onClick={actions.onReset}>
              <Power size={14} /> Reset
            </Button>
          )}
          {session !== "disconnected" && (
            <Button variant="text" onClick={actions.onDisconnect}>
              <RefreshCw size={13} /> Disconnect
            </Button>
          )}
        </div>
      )}
    </motion.button>
  );
}

export function DevicePage() {
  const { state, dispatch, setMode, connectDevice, disconnectDevice, resetDevice, toast } = useBus();
  const [confirmReset, setConfirmReset] = useState(false);
  const v = state.mode !== "none" ? VENDORS[state.mode] : null;
  const daemon = state.source === "daemon";
  const busy = state.job !== null && !state.job.finished;
  const selected = state.devices.find((d) => d.path === state.selectedPath) ?? null;

  return (
    <div className="page">
      <div className="device-hero">
        <motion.div
          className="card pad device-card"
          variants={item}
          initial="initial"
          animate="animate"
          key={daemon ? "daemon" : state.mode === "none" ? "empty" : state.mode}
          style={daemon && state.devices.length > 0 ? { width: 640 } : undefined}
        >
          <AnimatePresence mode="wait">
            {daemon ? (
              <motion.div key="daemon" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.15 }}>
                {state.daemonGone ? (
                  <>
                    <div className="m3-empty-icon"><TriangleAlert size={38} strokeWidth={1.6} /></div>
                    <h2>Backend stopped</h2>
                    <p className="sub">{state.daemonGone}. Restart the app to reconnect to the Zig daemon.</p>
                  </>
                ) : state.devices.length === 0 ? (
                  <>
                    <div className="m3-empty-icon">
                      <motion.span
                        animate={{ opacity: [0.5, 1, 0.5] }}
                        transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
                        style={{ display: "grid", placeItems: "center" }}
                      >
                        <Radio size={40} strokeWidth={1.6} />
                      </motion.span>
                    </div>
                    <h2>Listening for devices</h2>
                    <p className="sub">
                      Plug the device in and enter its download mode. The Zig daemon
                      classifies the USB port automatically.
                    </p>
                  </>
                ) : (
                  <div style={{ textAlign: "left" }}>
                    <div className="flash-head" style={{ marginBottom: 14 }}>
                      <b>Detected devices</b>
                      <span className="note">{state.devices.length} on the bus</span>
                    </div>
                    <motion.div variants={stagger} initial="initial" animate="animate" style={{ display: "grid", gap: 10 }}>
                      {state.devices.map((d) => (
                        <DeviceCard
                          key={d.path}
                          dev={d}
                          selected={d.path === state.selectedPath}
                          onSelect={() => dispatch({ type: "devSelect", path: d.path })}
                          busy={busy}
                          session={state.session}
                          actions={{
                            onConnect: () => connectDevice(d),
                            onOpenFlash: () => dispatch({ type: "page", page: "flash" }),
                            onReset: () => resetDevice(),
                            onDisconnect: () => disconnectDevice(),
                          }}
                        />
                      ))}
                    </motion.div>
                  </div>
                )}
              </motion.div>
            ) : v ? (
              <motion.div
                key="found"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.2, ease: [0.05, 0.7, 0.1, 1] }}
              >
                <div className="m3-empty-icon" style={{ background: `color-mix(in srgb, ${v.color} 14%, transparent)`, color: v.color }}>
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
              <motion.div key="empty" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} transition={{ duration: 0.15 }}>
                <div className="m3-empty-icon">
                  <motion.span animate={{ opacity: state.scanning ? [0.5, 1, 0.5] : 1 }} transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }} style={{ display: "grid", placeItems: "center" }}>
                    <Radio size={40} strokeWidth={1.6} />
                  </motion.span>
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

      {!daemon && (
        <motion.div className="vendor-strip" variants={stagger} initial="initial" animate="animate">
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
      )}

      {daemon && selected && (
        <p style={{ textAlign: "center", fontSize: 12, color: "var(--text-3)", marginTop: 24 }} className="mono">
          {selected.path}
        </p>
      )}

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

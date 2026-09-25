import { motion, AnimatePresence } from "motion/react";
import { BusProvider, useBus } from "./state/bus";
import { Rail } from "./components/Rail";
import { Toasts } from "./components/Toasts";
import { DevicePage } from "./pages/DevicePage";
import { FlashPage } from "./pages/FlashPage";
import { ConsolePage } from "./pages/ConsolePage";
import { VENDORS } from "./state/vendors";
import { pageVariants } from "./lib/motion";

const TITLES: Record<string, string> = {
  device: "Device",
  flash: "Flash",
  console: "Console",
};

function Shell() {
  const { state, setMode } = useBus();
  const daemon = state.source === "daemon";
  const v = state.mode !== "none" ? VENDORS[state.mode] : null;
  const dev = daemon ? state.devices.find((d) => d.path === state.selectedPath) ?? null : null;
  const devMeta = dev ? VENDORS[dev.mode as keyof typeof VENDORS] : null;

  const statusText = daemon
    ? state.daemonGone
      ? "Daemon gone"
      : dev
        ? `${devMeta?.name ?? "Device"} · ${state.session.replace("_", " ")}`
        : "Listening"
    : v
      ? `${v.name} · ${v.modeLabel}`
      : state.scanning
        ? "Scanning"
        : "No device";
  const statusColor = daemon
    ? state.session === "firehose_ready"
      ? "var(--ok)"
      : state.session === "needs_loader"
        ? "var(--warn)"
        : devMeta?.color ?? "var(--text-3)"
    : v?.color ?? (state.scanning ? "var(--accent)" : "var(--text-3)");

  return (
    <div className="app">
      <Rail />
      <div className="main">
        <header className="topbar">
          <h1>{TITLES[state.page]}</h1>
          <div className="topbar-right">
            {!daemon && (
              <select
                className="select"
                value={state.mode}
                onChange={(e) => setMode(e.target.value as typeof state.mode)}
                title="Design-review switch: simulate a connected device"
              >
                <option value="none" disabled={state.scanning}>
                  {state.scanning ? "Searching…" : "Sim device…"}
                </option>
                {state.mode !== "none" && v && (
                  <option value={state.mode}>{v.name} · {v.modeLabel}</option>
                )}
                {(Object.keys(VENDORS) as (keyof typeof VENDORS)[])
                  .filter((id) => id !== state.mode)
                  .map((id) => (
                    <option key={id} value={id}>{VENDORS[id].name} · {VENDORS[id].modeLabel}</option>
                  ))}
              </select>
            )}
            <span className="pill">
              <span
                className={`dot ${v || state.scanning || (daemon && dev) ? "live" : ""}`}
                style={{
                  background: statusColor,
                  ["--dot-glow" as string]: (v ?? devMeta) ? `color-mix(in srgb, ${(v ?? devMeta)!.color} 40%, transparent)` : undefined,
                }}
              />
              {statusText}
            </span>
          </div>
        </header>

        <div className="content">
          <AnimatePresence mode="wait">
            <motion.div
              key={state.page}
              variants={pageVariants}
              initial="initial"
              animate="animate"
              exit="exit"
              style={{ height: "100%" }}
            >
              {state.page === "device" && <DevicePage />}
              {state.page === "flash" && <FlashPage />}
              {state.page === "console" && <ConsolePage />}
            </motion.div>
          </AnimatePresence>
        </div>
      </div>
      <Toasts />
    </div>
  );
}

export default function App() {
  return (
    <BusProvider>
      <Shell />
    </BusProvider>
  );
}

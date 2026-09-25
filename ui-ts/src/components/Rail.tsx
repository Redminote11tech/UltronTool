import { motion } from "motion/react";
import { Cpu, HardDriveDownload, Settings, Terminal } from "lucide-react";
import { useBus } from "../state/bus";
import type { Page } from "../state/bus";
import { railTransition } from "../lib/motion";
import { BrandMark } from "./BrandMark";

const NAV: { id: Page; icon: typeof Cpu; label: string }[] = [
  { id: "device", icon: Cpu, label: "Device" },
  { id: "flash", icon: HardDriveDownload, label: "Flash" },
  { id: "console", icon: Terminal, label: "Console" },
];

/** M3 navigation rail: icon-in-pill + label, active indicator morphs. */
export function Rail() {
  const { state, dispatch } = useBus();
  return (
    <nav className="rail">
      <motion.div
        className="rail-brand"
        initial={{ opacity: 0, scale: 0.9 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 0.25, ease: railTransition.ease }}
        title="Ultron"
      >
        <BrandMark size={28} />
      </motion.div>

      {NAV.map(({ id, icon: Icon, label }) => {
        const active = state.page === id;
        return (
          <button
            key={id}
            className={`rail-item stateable ${active ? "active" : ""}`}
            onClick={() => dispatch({ type: "page", page: id })}
            aria-label={label}
            title={label}
          >
            <span className="rail-iconbox">
              {active && (
                <motion.span
                  layoutId="rail-active"
                  className="rail-active-pill"
                  style={{ position: "absolute", inset: 0, borderRadius: 999, background: "var(--md-secondary-container)" }}
                  transition={railTransition}
                />
              )}
              <motion.span
                className="rail-glyph"
                transition={railTransition}
                style={{ display: "grid", placeItems: "center" }}
              >
                <Icon size={21} strokeWidth={active ? 2 : 1.8} />
              </motion.span>
            </span>
            <span className="rail-label">{label}</span>
          </button>
        );
      })}

      <div className="rail-spacer" />
      <button className="rail-item" aria-label="Settings" title="Settings (sim)" disabled style={{ opacity: 0.4 }}>
        <span className="rail-iconbox">
          <span className="rail-glyph" style={{ display: "grid", placeItems: "center" }}>
            <Settings size={20} strokeWidth={1.8} />
          </span>
        </span>
        <span className="rail-label">Settings</span>
      </button>
    </nav>
  );
}

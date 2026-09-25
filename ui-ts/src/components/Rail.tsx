import { motion } from "motion/react";
import { Cpu, HardDriveDownload, Settings, Terminal } from "lucide-react";
import { useBus } from "../state/bus";
import type { Page } from "../state/bus";
import { springSnappy } from "../lib/motion";
import { BrandMark } from "./BrandMark";

const NAV: { id: Page; icon: typeof Cpu; label: string }[] = [
  { id: "device", icon: Cpu, label: "Device" },
  { id: "flash", icon: HardDriveDownload, label: "Flash" },
  { id: "console", icon: Terminal, label: "Console" },
];

export function Rail() {
  const { state, dispatch } = useBus();
  return (
    <nav className="rail">
      <motion.div
        className="rail-brand"
        initial={{ opacity: 0, scale: 0.8 }}
        animate={{ opacity: 1, scale: 1, rotate: [0, 6, 0] }}
        transition={{ ...springSnappy, rotate: { duration: 0.9, delay: 0.2 } }}
        title="Ultron"
      >
        <BrandMark size={26} />
      </motion.div>

      {NAV.map(({ id, icon: Icon, label }) => {
        const active = state.page === id;
        return (
          <button
            key={id}
            className="rail-btn"
            onClick={() => dispatch({ type: "page", page: id })}
            aria-label={label}
            title={label}
          >
            {active && (
              <motion.span
                layoutId="rail-active"
                className="rail-pill"
                transition={springSnappy}
              />
            )}
            <motion.span
              className="rail-glyph"
              whileHover={{ scale: 1.12, rotate: -3 }}
              whileTap={{ scale: 0.88 }}
              transition={springSnappy}
              style={{ display: "grid", placeItems: "center" }}
            >
              <Icon size={20} strokeWidth={active ? 2.2 : 1.8} />
            </motion.span>
          </button>
        );
      })}

      <div className="rail-spacer" />
      <button className="rail-btn" aria-label="Settings" title="Settings (sim)" disabled style={{ opacity: 0.4 }}>
        <Settings size={19} strokeWidth={1.8} />
      </button>
    </nav>
  );
}

import { motion } from "motion/react";
import { EASE_EMPHASIZED } from "../lib/motion";

export function Switch({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      className={`switch ${on ? "on" : ""}`}
      role="switch"
      aria-checked={on}
      onClick={() => onChange(!on)}
    >
      <motion.span
        className="switch knob"
        animate={{
          left: on ? 24 : 5,
          width: on ? 24 : 18,
          height: on ? 24 : 18,
          top: on ? 2 : 5,
          backgroundColor: on ? "var(--md-on-primary)" : "var(--text-2)",
        }}
        transition={{ duration: 0.2, ease: EASE_EMPHASIZED }}
      />
    </button>
  );
}

export function SwitchRow({
  title,
  note,
  on,
  onChange,
  danger,
}: {
  title: string;
  note?: string;
  on: boolean;
  onChange: (v: boolean) => void;
  danger?: boolean;
}) {
  return (
    <div className="switch-row">
      <div className="switch-label">
        <b className={danger && on ? "danger-note" : undefined}>{title}</b>
        {note && <span>{note}</span>}
      </div>
      <Switch on={on} onChange={onChange} />
    </div>
  );
}

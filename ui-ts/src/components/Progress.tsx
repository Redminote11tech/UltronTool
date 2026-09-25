import { motion } from "motion/react";
import { EASE_EMPHASIZED } from "../lib/motion";

/** M3 linear progress: thin track, active indicator easing toward the value,
 * stop-dot separator. `indeterminate` shows the spec's scanning bar. */
export function Progress({ value, total }: { value: number; total: number }) {
  const pct = total > 0 ? Math.min(100, (value / total) * 100) : 0;
  return (
    <div
      className="prog-track"
      role="progressbar"
      aria-valuenow={Math.round(pct)}
      aria-valuemin={0}
      aria-valuemax={100}
    >
      <motion.div
        className="prog-fill"
        style={{ width: `${pct}%` }}
        animate={{ width: `${pct}%` }}
        initial={false}
        transition={{ duration: 0.3, ease: EASE_EMPHASIZED }}
      />
      <span className="prog-stop" />
    </div>
  );
}

export function IndeterminateProgress() {
  return <div className="prog-track indeterminate" aria-label="loading" />;
}

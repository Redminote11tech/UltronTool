import { motion } from "motion/react";

/** Spring-following progress bar with a sheen sweep while running. */
export function Progress({ value, total }: { value: number; total: number }) {
  const pct = total > 0 ? Math.min(100, (value / total) * 100) : 0;
  return (
    <div className="prog-track">
      <motion.div
        className="prog-fill"
        animate={{ width: `${pct}%` }}
        transition={{ type: "spring", stiffness: 90, damping: 22 }}
      />
    </div>
  );
}

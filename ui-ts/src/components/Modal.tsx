import { motion, AnimatePresence } from "motion/react";
import type { ReactNode } from "react";
import { dialog } from "../lib/motion";

/** M3 basic dialog: 28dp corners on surface-container-high, scrim behind. */
export function Modal({ open, children }: { open: boolean; children: ReactNode }) {
  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="modal-back"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.15 }}
        >
          <motion.div className="modal-panel" variants={dialog} initial="initial" animate="animate" exit="exit">
            {children}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

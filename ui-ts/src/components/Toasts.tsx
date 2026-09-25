import { motion, AnimatePresence } from "motion/react";
import { CheckCircle2, XCircle } from "lucide-react";
import { useBus } from "../state/bus";
import { snackbar } from "../lib/motion";

/** M3 snackbars: inverse-surface, bottom-left, quiet. */
export function Toasts() {
  const { state, dispatch } = useBus();
  return (
    <div className="toasts">
      <AnimatePresence>
        {state.toasts.map((t) => (
          <motion.div
            key={t.id}
            className="toast"
            variants={snackbar}
            initial="initial"
            animate="animate"
            exit="exit"
            onAnimationComplete={() => {
              window.setTimeout(() => dispatch({ type: "toastGone", id: t.id }), 3600);
            }}
          >
            {t.ok ? (
              <CheckCircle2 size={18} color="var(--ok)" />
            ) : (
              <XCircle size={18} color="var(--danger-strong)" />
            )}
            <div className="msg">
              <b>{t.title}</b>
              {t.body && <span>{t.body}</span>}
            </div>
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}

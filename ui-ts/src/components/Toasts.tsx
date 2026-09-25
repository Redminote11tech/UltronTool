import { motion, AnimatePresence } from "motion/react";
import { CheckCircle2, XCircle } from "lucide-react";
import { useBus } from "../state/bus";
import { springGentle } from "../lib/motion";

export function Toasts() {
  const { state, dispatch } = useBus();
  return (
    <div className="toasts">
      <AnimatePresence>
        {state.toasts.map((t) => (
          <motion.div
            key={t.id}
            className="toast"
            initial={{ opacity: 0, x: 48, scale: 0.96 }}
            animate={{ opacity: 1, x: 0, scale: 1 }}
            exit={{ opacity: 0, x: 24, scale: 0.97 }}
            transition={springGentle}
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

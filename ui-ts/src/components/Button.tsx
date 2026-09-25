import { motion, AnimatePresence } from "motion/react";
import { useRef, useState } from "react";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import { springSnappy } from "../lib/motion";

type Variant = "default" | "primary" | "ghost" | "danger";

/** Every button answers the click with a spring press (scale 0.965) and a
 * 1px lift on hover — the tactile baseline for the whole app. */
export function Button({
  variant = "default",
  large,
  block,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; large?: boolean; block?: boolean }) {
  const cls = ["btn", variant !== "default" ? variant : "", large ? "lg" : "", block ? "block" : ""]
    .filter(Boolean)
    .join(" ");
  return (
    <motion.button
      className={cls}
      whileHover={rest.disabled ? undefined : { y: -1 }}
      whileTap={rest.disabled ? undefined : { scale: 0.965 }}
      transition={springSnappy}
      {...(rest as object)}
    >
      {children}
    </motion.button>
  );
}

/**
 * Hold-to-confirm: the guard rail for destructive ops. The fill sweeps left→
 * right while held (~900ms); release early and it drains back. Visualizes
 * commitment instead of nagging with a second dialog.
 */
export function HoldButton({
  onConfirm,
  label,
  holdingLabel = "Keep holding…",
  className = "btn danger lg block hold",
  disabled,
}: {
  onConfirm: () => void;
  label: ReactNode;
  holdingLabel?: string;
  className?: string;
  disabled?: boolean;
}) {
  const [progress, setProgress] = useState(0);
  const [holding, setHolding] = useState(false);
  const raf = useRef(0);
  const start = useRef(0);
  const DONE_MS = 900;

  const tick = () => {
    const p = Math.min(1, (performance.now() - start.current) / DONE_MS);
    setProgress(p);
    if (p >= 1) {
      stop();
      onConfirm();
      return;
    }
    raf.current = requestAnimationFrame(tick);
  };

  const begin = () => {
    if (disabled) return;
    setHolding(true);
    start.current = performance.now();
    raf.current = requestAnimationFrame(tick);
  };

  const stop = () => {
    cancelAnimationFrame(raf.current);
    setHolding(false);
    setProgress(0);
  };

  return (
    <motion.button
      className={className}
      disabled={disabled}
      onPointerDown={begin}
      onPointerUp={stop}
      onPointerLeave={(e) => {
        if (e.buttons !== 0) stop();
      }}
      whileTap={disabled ? undefined : { scale: 0.98 }}
      transition={springSnappy}
    >
      <span
        className="hold-fill"
        style={{ transform: `scaleX(${progress})`, opacity: holding ? 1 : 0, transition: holding ? "none" : "opacity 200ms" }}
      />
      <span style={{ position: "relative", display: "inline-flex", alignItems: "center", gap: 8 }}>
        <AnimatePresence mode="wait" initial={false}>
          <motion.span
            key={holding ? "h" : "l"}
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -4 }}
            transition={{ duration: 0.12 }}
            style={{ display: "inline-flex", alignItems: "center", gap: 8 }}
          >
            {holding ? holdingLabel : label}
          </motion.span>
        </AnimatePresence>
      </span>
    </motion.button>
  );
}

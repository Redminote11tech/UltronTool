import { motion, AnimatePresence } from "motion/react";
import { useRef, useState } from "react";
import type { ButtonHTMLAttributes, ReactNode } from "react";

type Variant = "filled" | "tonal" | "outlined" | "text" | "error";

/** M3 buttons: pill shape + state layers; no lift, no scale. */
export function Button({
  variant = "text",
  large,
  block,
  children,
  className,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; large?: boolean; block?: boolean }) {
  const cls = ["btn", variant, large ? "lg" : "", block ? "block" : "", className ?? ""]
    .filter(Boolean)
    .join(" ");
  return (
    <button className={cls} {...rest}>
      {children}
    </button>
  );
}

/**
 * Hold-to-confirm for destructive ops (kept from the previous design — the
 * UX idea survives the reskin): fill sweeps while held (~900ms), drains back
 * on early release.
 */
export function HoldButton({
  onConfirm,
  label,
  holdingLabel = "Keep holding…",
  className = "btn error lg block",
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
    <button
      className={className + " hold"}
      disabled={disabled}
      onPointerDown={begin}
      onPointerUp={stop}
      onPointerLeave={(e) => {
        if (e.buttons !== 0) stop();
      }}
    >
      <span
        className="hold-fill"
        style={{ transform: `scaleX(${progress})`, opacity: holding ? 1 : 0, transition: holding ? "none" : "opacity 200ms" }}
      />
      <span style={{ position: "relative", display: "inline-flex", alignItems: "center", gap: 8 }}>
        <AnimatePresence mode="wait" initial={false}>
          <motion.span
            key={holding ? "h" : "l"}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.1 }}
            style={{ display: "inline-flex", alignItems: "center", gap: 8 }}
          >
            {holding ? holdingLabel : label}
          </motion.span>
        </AnimatePresence>
      </span>
    </button>
  );
}

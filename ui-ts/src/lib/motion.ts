/** M3 motion: expressive easings with fixed durations — no springs. Calm by
 * design: state layers answer presses, fades answer navigation. */
import type { Transition, Variants } from "motion/react";

export const EASE_EMPHASIZED = [0.2, 0, 0, 1] as const;
export const EASE_DECELERATE = [0.05, 0.7, 0.1, 1] as const;

/** M3 fade-through for page navigation: exit 90ms, enter 210ms + scale 92→100. */
export const pageVariants: Variants = {
  initial: { opacity: 0, scale: 0.98 },
  animate: { opacity: 1, scale: 1, transition: { duration: 0.21, ease: EASE_DECELERATE } },
  exit: { opacity: 0, transition: { duration: 0.09, ease: "linear" } },
};

export const fadeUp: Variants = {
  initial: { opacity: 0, y: 8 },
  animate: { opacity: 1, y: 0 },
  exit: { opacity: 0, y: -8 },
};

export const stagger: Variants = {
  animate: { transition: { staggerChildren: 0.04 } },
};

export const item: Variants = {
  initial: { opacity: 0, y: 8 },
  animate: { opacity: 1, y: 0, transition: { duration: 0.25, ease: EASE_EMPHASIZED } },
};

export const railTransition: Transition = { duration: 0.35, ease: EASE_EMPHASIZED };

export const snackbar: Variants = {
  initial: { opacity: 0, y: 24 },
  animate: { opacity: 1, y: 0, transition: { duration: 0.3, ease: EASE_DECELERATE } },
  exit: { opacity: 0, y: 16, transition: { duration: 0.15, ease: "easeIn" } },
};

export const dialog: Variants = {
  initial: { opacity: 0, scale: 0.9 },
  animate: { opacity: 1, scale: 1, transition: { duration: 0.25, ease: EASE_DECELERATE } },
  exit: { opacity: 0, scale: 0.95, transition: { duration: 0.15, ease: "easeIn" } },
};

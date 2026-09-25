/** Shared motion language: springs for anything physical, short tweens for
 * fades. Keep durations under ~300ms — snappy reads as "precise". */
import type { Transition, Variants } from "motion/react";

export const springGentle: Transition = { type: "spring", stiffness: 300, damping: 28 };
export const springSnappy: Transition = { type: "spring", stiffness: 480, damping: 34 };

export const fadeUp: Variants = {
  initial: { opacity: 0, y: 10 },
  animate: { opacity: 1, y: 0 },
  exit: { opacity: 0, y: -8 },
};

export const pageVariants: Variants = {
  initial: { opacity: 0, y: 12, filter: "blur(4px)" },
  animate: { opacity: 1, y: 0, filter: "blur(0px)", transition: { duration: 0.22, ease: [0.16, 1, 0.3, 1] } },
  exit: { opacity: 0, y: -8, filter: "blur(2px)", transition: { duration: 0.14, ease: "easeIn" } },
};

export const stagger: Variants = {
  animate: { transition: { staggerChildren: 0.055 } },
};

export const item: Variants = {
  initial: { opacity: 0, y: 12, scale: 0.985 },
  animate: { opacity: 1, y: 0, scale: 1, transition: springGentle },
};

import type { ButtonHTMLAttributes } from "react";

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


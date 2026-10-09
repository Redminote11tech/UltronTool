import { useEffect, useRef } from "react";
import type { ReactNode } from "react";

/** Native modal semantics: focus containment, Escape and focus restoration. */
export function Modal({ open, children, onClose, label = "Confirm operation" }: {
  open: boolean; children: ReactNode; onClose?: () => void; label?: string;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
    return () => { if (dialog.open) dialog.close(); };
  }, [open]);
  return <dialog ref={ref} className="modal-panel" aria-label={label}
    onCancel={() => onClose?.()} onClose={() => onClose?.()}>{children}</dialog>;
}

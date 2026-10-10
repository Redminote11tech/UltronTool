import { useEffect, useState } from "react";
import { useBus } from "../state/bus";
import { isTauri } from "../lib/tauri";
import { Modal } from "./Modal";
import { Button } from "./Button";

export function CloseGuard() {
  const [open, setOpen] = useState(false);
  const [closing, setClosing] = useState(false);
  const { toast, state } = useBus();
  const writing = /^(Flashing|Writing|Erasing)/i.test(state.job?.title || "");
  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void import("@tauri-apps/api/event").then(({ listen }) => listen("app-close-requested", () => setOpen(true))).then(fn => {
      if (cancelled) fn(); else unlisten = fn;
    });
    return () => { cancelled = true; unlisten?.(); };
  }, []);
  return <Modal open={open} onClose={() => { if (!closing) setOpen(false); }} label="Close during an operation">
    <h3>{closing ? "Waiting for the backend…" : "An operation is running"}</h3>
    <p>{closing ? "The window will close after the worker releases the device." : writing ? "Cancelling this write can leave the device partially flashed. Keep the window open to let it finish." : "Keep the window open to let the operation finish, or cancel and close after the backend releases the device."}</p>
    {!closing && <div className="modal-actions"><Button onClick={() => setOpen(false)}>Keep open</Button>
      <Button variant="error" onClick={() => {
        setClosing(true);
        void import("@tauri-apps/api/core").then(({ invoke }) => invoke("daemon_close")).catch(error => {
          setClosing(false); toast(false, "Could not close", String(error));
        });
      }}>Cancel operation and close</Button></div>}
  </Modal>;
}

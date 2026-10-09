
import { useEffect, useRef, useState } from "react";
import { Save, Trash2 } from "lucide-react";
import { useBus } from "../state/bus";
import type { Level } from "../state/bus";
import { Button } from "../components/Button";
import { Switch } from "../components/Switch";
import { clock } from "../lib/format";
import { saveLog } from "../lib/tauri";
import { formatLog } from "../lib/logExport";

const FILTERS: { id: "all" | Level; label: string }[] = [
  { id: "all", label: "All" },
  { id: "info", label: "Info" },
  { id: "protocol", label: "Protocol" },
  { id: "warn", label: "Warn" },
  { id: "error", label: "Error" },
];

export function ConsolePage() {
  const { state, dispatch, toast } = useBus();
  const [filter, setFilter] = useState<(typeof FILTERS)[number]["id"]>("all");
  const [autoscroll, setAutoscroll] = useState(true);
  const [saving, setSaving] = useState(false);
  const box = useRef<HTMLDivElement>(null);

  const lines = state.logs.filter((l) => filter === "all" || l.level === filter);

  useEffect(() => {
    if (autoscroll && box.current) box.current.scrollTop = box.current.scrollHeight;
  }, [lines.at(-1)?.id, autoscroll, filter]);

  return (
    <div className="page">
      <div className="console-toolbar">
        <div className="seg" aria-label="Log filters">
          {FILTERS.map((f) => (
            <button key={f.id} onClick={() => setFilter(f.id)} aria-pressed={filter === f.id} aria-selected={filter === f.id}>
              <span>{f.label}</span>
            </button>
          ))}
        </div>
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 14 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "var(--text-2)" }}>
            Autoscroll <Switch label="Autoscroll" on={autoscroll} onChange={setAutoscroll} />
          </label>
          <Button variant="text" onClick={() => { dispatch({ type: "clearLogs" }); toast(true, "Console cleared"); }}>
            <Trash2 size={14} /> Clear
          </Button>
          <Button variant="outlined" disabled={saving || state.logs.length === 0} onClick={() => {
            setSaving(true);
            void saveLog(formatLog(state.logs)).then(saved => { if (saved) toast(true, "Log saved"); }).catch(error => toast(false, "Export failed", String(error))).finally(() => setSaving(false));
          }}>
            <Save size={14} /> Save
          </Button>
        </div>
      </div>

      <div className="console" ref={box}>
        {lines.length === 0 && <p className="console-empty">No messages match this filter.</p>}
        {lines.map(line => <div key={line.id} className="logline">
          <span className="t mono">{clock(line.at)}</span><span className={`lv lv-${line.level}`}>{line.level.toUpperCase()}</span><span className="msg">{line.text}</span>
        </div>)}

      </div>
    </div>
  );
}

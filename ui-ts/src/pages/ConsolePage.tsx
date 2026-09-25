import { motion, AnimatePresence } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { Save, Trash2 } from "lucide-react";
import { useBus } from "../state/bus";
import type { Level } from "../state/bus";
import { Button } from "../components/Button";
import { Switch } from "../components/Switch";
import { clock } from "../lib/format";
import { springSnappy } from "../lib/motion";

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
  const box = useRef<HTMLDivElement>(null);

  const lines = state.logs.filter((l) => filter === "all" || l.level === filter);

  useEffect(() => {
    if (autoscroll && box.current) box.current.scrollTop = box.current.scrollHeight;
  }, [lines.length, autoscroll]);

  return (
    <div className="page">
      <div className="console-toolbar">
        <div className="seg" role="tablist">
          {FILTERS.map((f) => (
            <button key={f.id} onClick={() => setFilter(f.id)} role="tab" aria-selected={filter === f.id}>
              {filter === f.id && (
                <motion.span layoutId="seg-active" className="seg-active" transition={springSnappy} />
              )}
              <span>{f.label}</span>
            </button>
          ))}
        </div>
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 14 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "var(--text-2)" }}>
            Autoscroll <Switch on={autoscroll} onChange={setAutoscroll} />
          </label>
          <Button variant="ghost" onClick={() => { dispatch({ type: "clearLogs" }); toast(true, "Console cleared"); }}>
            <Trash2 size={14} /> Clear
          </Button>
          <Button variant="ghost" onClick={() => toast(true, "Log saved", "ultron-session.log (simulated)")}>
            <Save size={14} /> Save
          </Button>
        </div>
      </div>

      <div className="console" ref={box}>
        <AnimatePresence initial={false}>
          {lines.map((l) => (
            <motion.div
              key={l.id}
              className="logline"
              initial={{ opacity: 0, x: -8 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ duration: 0.14 }}
            >
              <span className="t mono">{clock(l.at)}</span>
              <span className={`lv lv-${l.level}`}>{l.level.toUpperCase()}</span>
              <span className={`msg ${l.level === "protocol" ? "protocol" : l.level === "warn" || l.level === "error" ? "plain" : ""}`}>
                {l.text}
              </span>
            </motion.div>
          ))}
        </AnimatePresence>
      </div>
    </div>
  );
}

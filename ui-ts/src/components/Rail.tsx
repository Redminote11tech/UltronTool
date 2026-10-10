import { Cpu, HardDriveDownload, Terminal, Database } from "lucide-react";
import { useBus } from "../state/bus";
import type { Page } from "../state/bus";
const iconUrl = new URL("../assets/ultron.svg", import.meta.url).href;
const NAV: { id: Page; icon: typeof Cpu; label: string }[] = [
  { id: "device", icon: Cpu, label: "Devices" },
  { id: "partitions", icon: Database, label: "Partitions" },
  { id: "flash", icon: HardDriveDownload, label: "XML plans" },
  { id: "console", icon: Terminal, label: "Session log" },
];
export function Rail() {
  const { state, dispatch } = useBus();
  return <nav className="rail" aria-label="Main navigation">
    <div className="rail-brand"><img className="brand-icon" src={iconUrl} alt="" aria-hidden="true" /><div><b>Ultron</b><span>Device recovery</span></div></div>
    <div className="nav-items">{NAV.map(({ id, icon: Icon, label }) => <button key={id}
      className={`rail-item ${state.page === id ? "active" : ""}`} aria-label={label} aria-current={state.page === id ? "page" : undefined}
      onClick={() => dispatch({ type: "page", page: id })}><Icon size={20} /><span>{label}</span></button>)}</div>
    <div className="rail-footer"><span className="beta-label">BETA 0.3.0</span><p>{state.source === "daemon" ? "Native Linux application" : "Browser preview · simulated"}</p></div>
  </nav>;
}

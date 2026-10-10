import { useState } from "react";
import { Cpu, Usb, ArrowRight, RefreshCw, PlugZap, Radio, Power, TriangleAlert } from "lucide-react";
import { useBus } from "../state/bus";
import { SIM_DEVICES, VENDORS } from "../state/vendors";
import type { Mode } from "../state/vendors";
import { Button } from "../components/Button";
import { SessionPanel } from "../components/SessionPanel";
import { Modal } from "../components/Modal";

export function DevicePage() {
  const { state, dispatch, setMode, connectDevice, disconnectDevice, resetDevice } = useBus();
  const [resetTarget, setResetTarget] = useState<string | null>(null);
  const real = state.source === "daemon";
  const busy = !!state.job && !state.job.finished;
  const selected = state.devices.find(dev => dev.path === state.selectedPath);
  const simulated = state.mode === "none" ? null : VENDORS[state.mode];
  const hex = (n: number) => n.toString(16).padStart(4, "0");
  const connected = state.session !== "disconnected";
  return <div className="page">
    {!real && <div className="notice"><Radio size={20} /><div><b>Simulation preview</b><p>No USB commands are sent. Select a scenario to explore the interface.</p></div>
      <select aria-label="Simulated device" className="select" value={state.mode} disabled={busy || state.scanning} onChange={e => setMode(e.target.value as Mode)}>
        {SIM_DEVICES.map(dev => <option key={dev.id} value={dev.id}>{dev.label}</option>)}
      </select></div>}
    <div className="device-layout">
      <section className="card device-panel">
        <div className="section-heading"><div><h2>Available devices</h2><p>{real ? "Download-mode devices detected over USB" : "Preview device"}</p></div><Usb size={23} /></div>
        {state.daemonGone ? <div className="empty-state"><TriangleAlert size={40} /><h3>Backend stopped</h3><p>{state.daemonGone}. Restart Ultron to reconnect.</p></div>
          : real && state.devices.length === 0 || !real && !simulated ? <div className="empty-state"><Usb size={42} strokeWidth={1.5} /><h3>{state.scanning ? "Searching…" : "Waiting for a device"}</h3><p>{real ? "Connect the device in its supported download mode. It will appear here automatically." : "Choose a simulated device above to start."}</p></div>
          : real ? <div className="device-list">{state.devices.map(dev => {
            const active = dev.path === state.selectedPath;
            const supported = dev.mode === "qualcomm_edl";
            return <div key={dev.path} className={`device-row ${active ? "selected" : ""}`}>
              <button className="device-select" disabled={busy || connected && !active} onClick={() => dispatch({ type: "devSelect", path: dev.path })} aria-pressed={active}>
                <span className="device-icon"><Cpu size={24} /></span><span className="device-copy"><b>{dev.label}</b><span>{dev.product || dev.manufacturer || dev.mode.replaceAll("_", " ")}</span><span className="mono">{hex(dev.vid)}:{hex(dev.pid)} · Bus {dev.bus} / address {dev.devnum}</span></span><span className="radio-indicator" aria-hidden="true" />
              </button>
              {!supported && <p className="device-note">Use GTK for this mode. Material 3 currently exposes Qualcomm EDL operations; crash-dump exports and other vendor flows remain in GTK.</p>}
              {active && supported && <div className="device-actions"><span className="session-label">{state.session === "needs_loader" ? "Sahara detected — load a programmer in the connection panel" : state.session === "firehose_ready" ? "Firehose connected" : "Not connected"}</span>
                {!connected ? <Button variant="filled" disabled={busy} onClick={() => connectDevice(dev)}><PlugZap size={17} />Probe device (no writes)</Button>
                  : <><Button variant="filled" disabled={busy || state.session !== "firehose_ready"} onClick={() => dispatch({ type: "page", page: "partitions" })}>Browse partitions<ArrowRight size={17} /></Button>
                    <Button variant="text" disabled={busy} onClick={disconnectDevice}><RefreshCw size={16} />Disconnect</Button>
                    <Button variant="text" disabled={busy || state.session !== "firehose_ready"} onClick={() => setResetTarget(dev.path)}><Power size={16} />Restart (Firehose)</Button></>}
              </div>}
            </div>;
          })}</div> : <div className="sim-device"><span className="device-icon"><Cpu size={30} /></span><h3>{simulated!.name}</h3><p>{simulated!.modeLabel}</p><p className="mono">{state.chip}</p><Button variant="filled" onClick={() => dispatch({ type: "page", page: "partitions" })}>Browse partitions<ArrowRight size={17} /></Button></div>}
        {selected && state.chip && <div className="chip-info"><b>Chip information</b><span className="mono">{state.chip}</span></div>}
      </section>
      {real && selected?.mode === "qualcomm_edl" ? <SessionPanel/> : <aside className="card guide"><h2>Connect first. Flash only if needed.</h2><ol className="steps">
        <li><span>1</span><div><b>Connect your device</b><p>Use a reliable USB cable and enter the vendor’s download mode.</p></div></li>
        <li><span>2</span><div><b>Load a matching programmer</b><p>Upload Firehose to RAM to enable storage access. No XML or firmware flash is required.</p></div></li>
        <li><span>3</span><div><b>Choose your task</b><p>Read partitions, save backups, or optionally inspect and flash an XML plan.</p></div></li>
      </ol><div className="guide-footer">Other vendors remain available in the GTK application.</div></aside>}
    </div>
    <Modal open={resetTarget !== null} label="Reset device" onClose={() => setResetTarget(null)}><h3>Reset this device?</h3><p>Ask the running Firehose programmer to restart the device (up to 10 seconds). Disconnect only releases the session and does not reboot.</p><p className="mono">{resetTarget}</p><div className="modal-actions"><Button onClick={() => setResetTarget(null)}>Cancel</Button><Button variant="filled" disabled={busy || resetTarget !== state.selectedPath || state.session !== "firehose_ready"} onClick={() => { resetDevice(); setResetTarget(null); }}>Reset device</Button></div></Modal>
  </div>;
}

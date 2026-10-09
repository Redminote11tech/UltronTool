import { FileText, FolderOpen, X, Loader2, HardDriveDownload, ArrowRight, CheckCircle2, TriangleAlert } from "lucide-react";
import { useRef, useState } from "react";
import { useBus } from "../state/bus";
import type { FlashPlan, Storage } from "../state/bus";
import { SLOTS, VENDORS } from "../state/vendors";
import type { SlotCfg } from "../state/vendors";
import { pickFiles } from "../lib/tauri";
import { Button } from "../components/Button";
import { SwitchRow } from "../components/Switch";
import { Modal } from "../components/Modal";
import { Progress } from "../components/Progress";
import { bytes, eta, rate } from "../lib/format";

const QUALCOMM_SLOTS: SlotCfg[] = [
  { id: "programmer", label: "Firehose programmer", hint: "A signed .mbn or .elf programmer for your device", required: true, fake: "firehose.mbn", fakeSize: 3_210_000 },
  { id: "rawprogram", label: "Rawprogram XML", hint: "The flash plan and its referenced raw image files", required: true, fake: "rawprogram0.xml", fakeSize: 84_000 },
  { id: "patch", label: "Patch XML", hint: "Optional partition table patches", required: false, fake: "patch0.xml", fakeSize: 12_000 },
  { id: "vip", label: "VIP digest tables", hint: "Required only when the programmer enforces signed digest tables", required: false, fake: "DigestsToSign", fakeSize: 0 },
];
export function FlashPage() {
  const { state, dispatch, toast, startFlash, cancelFlash, startFlashReal } = useBus();
  const { files, storage, skipInit, scope } = state.draft;
  const [attaching, setAttaching] = useState<string | null>(null);
  const pickerOpen = useRef(false);
  const [review, setReview] = useState<FlashPlan | "simulation" | null>(null);
  const real = state.source === "daemon";
  const selected = state.devices.find(dev => dev.path === state.selectedPath);
  const mode = state.mode === "none" ? null : state.mode;
  const slots = real ? QUALCOMM_SLOTS : mode ? SLOTS[mode] : [];
  const job = state.job;
  const running = !!job && !job.finished;
  const configured = state.session === "firehose_ready";
  const locked = running || real && configured;
  const supported = !real || selected?.mode === "qualcomm_edl" || selected?.mode === "qualcomm_crash";
  const missing = slots.some(slot => slot.required && !slot.disabledNote && !(real && configured && slot.id === "programmer") && !files[slot.id]);
  const canStart = !running && !attaching && !missing && (real ? !!selected && supported && !state.daemonGone && (configured || state.session === "needs_loader") : !!mode);
  const updateFile = (id: string, value: typeof files[string]) => dispatch({ type: "draftFiles", scope, update: previous => ({ ...previous, [id]: value }) });
  const pick = async (slot: SlotCfg) => {
    if (pickerOpen.current || running || slot.disabledNote || locked && ["programmer", "vip"].includes(slot.id)) return;
    if (!real) { updateFile(slot.id, { name: slot.fake, size: slot.fakeSize, paths: [] }); return; }
    pickerOpen.current = true; setAttaching(slot.id);
    try {
      const paths = await pickFiles({ directory: slot.id === "vip", multiple: !["vip", "programmer"].includes(slot.id), title: slot.label,
        filters: slot.id === "vip" ? undefined : [{ name: slot.label, extensions: slot.id === "programmer" ? ["mbn", "elf", "bin"] : ["xml"] }] });
      if (paths.length) updateFile(slot.id, { name: paths[0].split("/").pop() ?? paths[0], size: 0, paths });
    } catch (error) { toast(false, "File selection failed", String(error)); }
    finally { pickerOpen.current = false; setAttaching(null); }
  };
  const prepareReview = () => {
    if (!canStart) return;
    if (!real) { setReview("simulation"); return; }
    if (!selected) return;
    setReview({ target: { path: selected.path, bus: selected.bus, devnum: selected.devnum },
      programmer: configured ? undefined : files.programmer?.paths[0],
      files: [...files.rawprogram!.paths, ...(files.patch?.paths ?? [])], storage, skipInit,
      vipDir: configured ? state.configured?.vipDir || undefined : files.vip?.paths[0] });
  };
  if (real ? !selected || !supported : !mode) return <div className="card empty-state"><HardDriveDownload size={42} strokeWidth={1.5} /><h3>{selected && !supported ? "Use the GTK application" : "Choose a device first"}</h3><p>{selected && !supported ? "This vendor’s hardware flow is available in GTK. The TS backend currently supports Qualcomm." : "Select and connect a device before preparing a flash plan."}</p><Button variant="tonal" onClick={() => dispatch({ type: "page", page: "device" })}>Go to devices<ArrowRight size={17} /></Button></div>;
  const name = real ? selected!.label : VENDORS[mode!].name;
  return <div className="page">
    {!real && <div className="notice"><TriangleAlert size={20} /><div><b>Simulation only</b><p>Files and progress are fabricated. No data will be written to a device.</p></div></div>}
    {job && <section className="card pad job-card" aria-live="polite">
      {job.finished ? <div className={job.failed ? "banner-err" : "banner-ok"}>{job.failed ? <TriangleAlert size={18} /> : <CheckCircle2 size={18} />} {job.failed ? "Operation failed" : "Operation complete"}. Check the session log for details.</div>
        : <><div className="job-heading"><div><h2>{job.title}</h2><p>{job.label}</p></div><Button variant="outlined" onClick={cancelFlash}>Cancel operation</Button></div>
          <Progress value={job.fraction ?? 0} total={job.fraction === null ? 0 : 1} />
          <div className="prog-meta"><b>{job.fraction === null ? "Working…" : `${(job.fraction * 100).toFixed(1)}%`}</b>{job.total > 0 && <span className="mono">{bytes(job.value)} / {bytes(job.total)}</span>}{job.rate > 0 && <span className="mono">{rate(job.rate)}</span>}{job.eta > 0 && <span className="mono">{eta(job.eta)} remaining</span>}</div></>}
    </section>}
    <div className="flash-grid">
      <section><div className="flash-head"><b>Firmware files</b><span className="note">{name}{real ? ` · USB ${selected!.bus}:${selected!.devnum}` : " · simulated device"}</span></div>
        {slots.map(slot => {
          const file = files[slot.id];
          const slotLocked = running || !!slot.disabledNote || locked && ["programmer", "vip"].includes(slot.id);
          const actualVip = real && configured && slot.id === "vip" ? state.configured?.vipDir : null;
          return <div className={`slot ${file ? "filled" : ""}`} key={slot.id}>
            <div className="slot-title">{slot.id === "vip" ? <FolderOpen size={18} /> : <FileText size={18} />}<span>{slot.label}</span><span className="req">{slot.required && !(real && configured && slot.id === "programmer") ? "Required" : "Optional"}</span></div>
            <p className="slot-hint">{slot.disabledNote ?? (real && configured && slot.id === "programmer" ? "The programmer is already running on the device." : slot.hint)}</p>
            {actualVip ? <div className="slot-file"><span className="mono">{actualVip}</span></div> : file ? <div className="staged-paths">{(real ? file.paths : [file.name]).map(path => <div className="slot-file" key={path}><span className="mono">{path}</span></div>)}
              <Button variant="text" disabled={slotLocked} onClick={() => updateFile(slot.id, null)}><X size={15} />Remove</Button></div> : <Button variant="outlined" disabled={slotLocked || !!attaching} onClick={() => void pick(slot)}>{attaching === slot.id ? <Loader2 size={16} /> : <FolderOpen size={16} />}{attaching === slot.id ? "Choosing…" : real ? "Choose file" : "Stage sample"}</Button>}
          </div>;
        })}
      </section>
      <aside className="card pad plan-options"><h2>{real ? "Session settings" : "Preview plan"}</h2>
        {real ? <><div className="switch-row"><div className="switch-label"><b>Storage type</b><span>{configured ? "Configured on device" : "Applied when connecting or uploading the programmer"}</span></div>
          <select className="select" aria-label="Storage type" value={storage} disabled={locked} onChange={e => dispatch({ type: "draftSettings", scope, storage: e.target.value as Storage })}>{([['ufs','UFS'],['emmc','eMMC'],['spinor','SPI NOR'],['nand','NAND'],['nvme','NVMe']] as const).map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select></div>
          <SwitchRow title="Skip storage initialization" note="Use only if required by your programmer" on={skipInit} disabled={locked} onChange={skipInit => dispatch({ type: "draftSettings", scope, skipInit })} />
          {configured && <p className="settings-note">Disconnect to change storage or VIP configuration.</p>}
        </> : <p className="settings-note">Preview the {name} workflow with sample inputs. Firmware files and transfer speeds are simulated.</p>}
        <div className="plan-summary"><div className="summary-row"><span>Device</span><b>{name}</b></div><div className="summary-row"><span>Files staged</span><b>{Object.values(files).filter(Boolean).length}</b></div><div className="summary-row"><span>Session</span><b>{real ? state.session.replaceAll('_',' ') : "Simulation"}</b></div>{state.parts && <div className="summary-row"><span>Partitions</span><b>{state.parts.rows.length}</b></div>}</div>
        <Button variant="filled" large block disabled={!canStart} onClick={prepareReview}>{real ? "Review flash plan" : "Run simulation"}<ArrowRight size={17} /></Button>
        <p className="start-note">{running ? "Wait for the current operation to finish." : missing ? "Stage the required files to continue." : real && state.session === "disconnected" ? "Connect this device on the Devices page." : real ? "You’ll confirm the device and files before any writes." : "No hardware is modified."}</p>
      </aside>
    </div>
    <Modal open={review !== null} label={real ? "Review flash plan" : "Run simulation"} onClose={() => setReview(null)}>
      <h3>{real ? "Flash this device?" : "Run this simulation?"}</h3><p>{real ? "This XML plan can overwrite partitions or erase device data. Check every file and back up anything you need." : "This preview uses sample files and fabricated progress. No USB commands are sent."}</p>
      {review && review !== "simulation" && <><dl><dt>USB target</dt><dd>Bus {review.target.bus} · address {review.target.devnum}</dd><dt>Device path</dt><dd className="mono">{review.target.path}</dd><dt>Storage</dt><dd>{review.storage.toUpperCase()} · {review.skipInit ? "Skip initialization" : "Initialize storage"}</dd></dl><p>Programmer: <span className="mono">{review.programmer ?? "Already running"}</span></p><p>VIP tables: <span className="mono">{review.vipDir ?? "None"}</span></p><ul>{review.files.map(path => <li className="mono" key={path}>{path}</li>)}</ul></>}
      <div className="modal-actions"><Button onClick={() => setReview(null)}>Cancel</Button><Button variant={real ? "error" : "filled"} disabled={running} onClick={() => { if (review === "simulation") startFlash(); else if (review) startFlashReal(review); setReview(null); }}>{real ? "Flash device" : "Run simulation"}</Button></div>
    </Modal>
  </div>;
}

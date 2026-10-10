import { useRef, useState } from "react";
import { useBus } from "../state/bus";
import type { FlashPlan } from "../state/bus";
import type { FlashInspection } from "../state/daemon";
import { pickFiles } from "../lib/tauri";
import { Button } from "../components/Button";
import { Modal } from "../components/Modal";
import { bytes } from "../lib/format";
export function FlashPage() {
  const {state, dispatch, toast, inspectPlan, startFlashReal, startFlash} = useBus();
  const {files,scope,storage,skipInit} = state.draft;
  const [choosing,setChoosing] = useState(false);
  const picking = useRef(false);
  const [review,setReview] = useState<{plan:FlashPlan; inspection:FlashInspection} | null>(null);
  const [simReview,setSimReview] = useState(false);
  const busy = !!state.job && !state.job.finished;
  const real = state.source === "daemon";
  const selected = state.devices.find(dev=>dev.path === state.selectedPath);
  const ready = real && state.session === "firehose_ready" && !!selected && !state.daemonGone;
  const pick = async (id:"rawprogram"|"patch") => {
    if (picking.current || busy) return;
    picking.current=true;setChoosing(true);setReview(null);
    try {
      const paths = await pickFiles({multiple:true,title:`Choose ${id} XML`,filters:[{name:"XML",extensions:["xml"]}]});
      if(paths.length) dispatch({type:"draftFiles",scope,update:previous=>({...previous,[id]:{name:paths[0].split('/').pop()!,paths,size:0}})});
    } catch(error) {toast(false,"File selection failed",String(error));}
    finally {picking.current=false;setChoosing(false);}
  };
  const inspect = async () => {
    if(!ready || !selected || !files.rawprogram || busy) return;
    const plan:FlashPlan = {target:{path:selected.path,bus:selected.bus,devnum:selected.devnum},files:[...files.rawprogram.paths,...(files.patch?.paths ?? [])],storage,skipInit,vipDir:state.configured?.vipDir || undefined};
    if (new Set(plan.files).size !== plan.files.length) {toast(false,"XML selected twice","Remove the duplicate XML file before inspecting the plan."); return;}
    try {
      const inspection = await inspectPlan(plan.files);
      setReview({plan:{...plan,reviewDigest:inspection.digest},inspection});
    } catch(error) {toast(false,"Plan inspection failed",String(error));}
  };
  const currentFiles = JSON.stringify([...(files.rawprogram?.paths ?? []),...(files.patch?.paths ?? [])]);
  const reviewValid = !!review && ready && !busy && review.plan.target.path === state.selectedPath && selected?.bus === review.plan.target.bus && selected?.devnum === review.plan.target.devnum && JSON.stringify(review.plan.files) === currentFiles;
  return <div className="page">
    {!real ? <section className="card pad"><h2>Simulation preview</h2><p>No USB commands are sent. This preview cannot inspect real XML files or partitions.</p><Button disabled={busy || state.mode === "none"} onClick={()=>setSimReview(true)}>Preview simulated flash</Button></section> : !ready ? <section className="card pad"><h2>Load Firehose first</h2><p>Flashing is optional. Connect a programmer on Devices first; you can then read partitions or save backups without choosing an XML file.</p><Button onClick={()=>dispatch({type:"page",page:"device"})}>Go to devices / load programmer</Button></section> : <>
      <section className="notice"><div><b>Optional firmware flashing</b><p>Only use this page if you intend to write firmware. Reading partitions and saving backups are separate tasks.</p></div><Button variant="text" onClick={()=>dispatch({type:"page",page:"partitions"})}>Read partitions / backups</Button></section>
      <div className="flash-grid"><section>{(["rawprogram","patch"] as const).map(id=><div className="slot" key={id}><div className="slot-title"><b>{id === "rawprogram" ? "Rawprogram XML" : "Patch XML"}</b><span className="req">{id === "rawprogram" ? "Needed for this flash action" : "Optional"}</span></div><p className="slot-hint">{id === "rawprogram" ? "Defines image writes and erase ranges. Referenced images must be present beside the XML or at their specified paths." : "Defines disk patches, often changes to the partition table."}</p>{files[id]?.paths.map(path=><div className="slot-file mono" key={path}>{path}</div>)}<div className="device-actions"><Button variant="outlined" disabled={busy || choosing} onClick={()=>void pick(id)}>Choose {id} XML…</Button>{files[id] && <Button variant="text" disabled={busy || choosing} onClick={()=>{setReview(null);dispatch({type:"draftFiles",scope,update:previous=>({...previous,[id]:null})});}}>Clear</Button>}</div></div>)}</section>
      <aside className="card pad"><h2>Inspect before writing</h2><p>Inspection uses the same XML parser as execution and does not write to the device.</p><dl><dt>Connected target</dt><dd>{selected!.label} · USB {selected!.bus}:{selected!.devnum}</dd><dt>Storage</dt><dd>{state.configured?.storage.toUpperCase()}</dd></dl><Button block disabled={busy || choosing || !files.rawprogram} onClick={()=>void inspect()}>Inspect XML operations…</Button><p className="note">The review lists each image write, erase range and disk patch. XML changes after review stop the flash and require a new inspection.</p></aside></div>
    </>}
    <Modal open={!!review} label="Review XML operations" onClose={()=>setReview(null)}><h3>Review operations before flashing</h3><p>This is optional and may overwrite device data. Back up anything you need first.</p>{review && <><p>USB {review.plan.target.bus}:{review.plan.target.devnum} · {review.plan.storage.toUpperCase()}</p><p className="mono">{review.plan.target.path}</p><p>{review.plan.skipInit ? "Storage opening skipped during connection" : "Normal storage access configured"} · VIP tables: <span className="mono">{review.plan.vipDir || "Not used"}</span></p><details><summary>XML files reviewed ({review.plan.files.length})</summary><ul>{review.plan.files.map((path,i)=><li className="mono" key={`${i}:${path}`}>{path}</li>)}</ul></details><div className="review-table table-scroll"><table className="partition-table"><thead><tr><th>Action / partition</th><th>LUN / start sector</th><th>Image / size</th></tr></thead><tbody>{review.inspection.operations.map((op,i)=><tr key={i}><td><b>{op.label}</b><br/>{{program:"Write image",erase:"Erase",patch:"Patch disk",set_bootable:"Set bootable LUN"}[op.kind]}</td><td>LUN {op.lun}<br/><span className="mono">{op.start || "—"}</span>{op.sectors > 0 && <p>{op.sectors} sectors</p>}</td><td><span className="mono">{op.image || "Device storage modification"}</span><br/>{op.bytes ? bytes(op.bytes) : op.kind === "program" ? "Size derived from image / session if not declared" : "See range / patch details"}<p className="note">{op.detail}</p></td></tr>)}</tbody></table></div><p>Unlabelled ranges and disk patches are shown as ranges rather than guessing a partition name. Bootable-LUN changes are listed explicitly when the backend adds them.</p>{!reviewValid && <p className="banner-err">The device, session or files changed. Close and inspect the plan again.</p>}</>}
      <div className="modal-actions"><Button onClick={()=>setReview(null)}>Close without flashing</Button><Button variant="error" disabled={!reviewValid} onClick={()=>{if(reviewValid && review) startFlashReal(review.plan);setReview(null);}}>Flash these operations</Button></div></Modal>
    <Modal open={simReview} label="Run simulation" onClose={()=>setSimReview(false)}><h3>Run simulated flash?</h3><p>All progress is fabricated; no storage or USB commands are used.</p><div className="modal-actions"><Button onClick={()=>setSimReview(false)}>Cancel</Button><Button disabled={busy} onClick={()=>{startFlash();setSimReview(false);}}>Run simulation</Button></div></Modal>
  </div>;
}

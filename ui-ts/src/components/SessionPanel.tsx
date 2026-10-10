import { useRef, useState } from "react";
import { useBus } from "../state/bus";
import type { Storage } from "../state/bus";
import { pickFiles } from "../lib/tauri";
import { Button } from "./Button";
import { SwitchRow } from "./Switch";
export function SessionPanel() {
  const {state, dispatch, uploadLoader, toast} = useBus();
  const [choosing, setChoosing] = useState(false);
  const picking = useRef(false);
  const {scope, files, storage, skipInit} = state.draft;
  const busy = !!state.job && !state.job.finished;
  const ready = state.session === "firehose_ready";
  const locked = busy || ready;
  const choose = async (id: "programmer" | "vip") => {
    if (picking.current || locked) return;
    picking.current = true; setChoosing(true);
    try {
      const paths = await pickFiles({directory:id === "vip", title:id === "programmer" ? "Choose Firehose programmer" : "Choose VIP digest directory", filters:id === "programmer" ? [{name:"Programmer",extensions:["mbn","elf","bin"]}] : undefined});
      if (paths.length) dispatch({type:"draftFiles",scope,update:previous=>({...previous,[id]:{name:paths[0].split('/').pop()!,size:0,paths}})});
    } catch(error) {toast(false,"Could not choose file",String(error));}
    finally {picking.current = false; setChoosing(false);}
  };
  return <section className="card pad session-panel"><h2>{ready ? "Firehose connected" : "Connect a Firehose programmer"}</h2><p className="settings-note">{ready ? "Partition browsing and backups are available. Flashing firmware is optional. Disconnect leaves the programmer running; restarting asks it to reboot the device." : "Probe the device, then upload a matching signed programmer. This loads the programmer into RAM; it does not flash firmware or erase storage."}</p>
    {!ready && <><div className="slot-file mono">{files.programmer?.paths[0] || "No programmer selected"}</div><Button variant="outlined" disabled={locked || choosing} onClick={()=>void choose("programmer")}>Choose programmer</Button></>}
    <div className="switch-row"><div className="switch-label"><b>Storage</b><span>{ready ? "Actual configured storage" : "Used for programmer configuration"}</span></div><select aria-label="Storage type" className="select" disabled={locked} value={storage} onChange={e=>dispatch({type:"draftSettings",scope,storage:e.target.value as Storage})}>{["ufs","emmc","spinor","nand","nvme"].map(value=><option key={value} value={value}>{value.toUpperCase()}</option>)}</select></div>
    <p className="settings-note">Storage access opens the existing UFS/eMMC device for sector reads and writes. Connecting does not send formatting, erase or UFS provisioning commands.</p>
    <details className="session-advanced"><summary>Advanced programmer options</summary><div className="session-advanced-body">
    <SwitchRow title="Skip opening storage during connection" note="Compatibility option (SkipStorageInit). Leave off for normal partition access; enable only when your programmer’s instructions require it. This does not provision the chip." disabled={locked} on={skipInit} onChange={skipInit=>dispatch({type:"draftSettings",scope,skipInit})}/>
    <p className="settings-note">VIP digest tables: <span className="mono">{ready ? state.configured?.vipDir || "Not used" : files.vip?.paths[0] || "Not selected (normally unnecessary)"}</span></p>
    {!ready && <div className="device-actions"><Button variant="text" disabled={locked || choosing} onClick={()=>void choose("vip")}>Choose VIP directory (optional)</Button>{files.vip && <Button variant="text" disabled={locked || choosing} onClick={()=>dispatch({type:"draftFiles",scope,update:previous=>({...previous,vip:null})})}>Clear VIP</Button>}
      </div>}
    </div></details>
    {!ready && <><Button block variant="filled" disabled={locked || choosing || state.session !== "needs_loader" || !files.programmer} onClick={()=>uploadLoader(files.programmer!.paths[0],storage,skipInit,files.vip?.paths[0])}>Load programmer</Button><p className="settings-note">Loads into RAM. Firmware flashing is a separate action.</p></>}
    {!ready && <p className="note">{state.session === "needs_loader" ? "Once loaded, open Partitions to inspect or back up the device. Restart uses Firehose; a bare EDL device must be restarted manually if the programmer cannot load." : "Use Probe device above first. A running Firehose programmer is detected automatically."}</p>}
  </section>;
}

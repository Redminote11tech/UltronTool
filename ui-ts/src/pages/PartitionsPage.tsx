import { useRef, useState } from "react";
import { useBus } from "../state/bus";
import { Button } from "../components/Button";
import { pickSavePath } from "../lib/tauri";
import { bytes } from "../lib/format";
export function PartitionsPage() {
  const {state, dispatch, partitionJob, toast} = useBus();
  const [filter,setFilter] = useState("");
  const [choosing,setChoosing] = useState(false);
  const picking = useRef(false);
  const target = state.selectedPath;
  const parts = state.parts;
  const busy = !!state.job && !state.job.finished;
  const available = state.source === "daemon" && state.session === "firehose_ready" && !!target && !state.daemonGone;
  const refresh = (lun: number) => {if(target) partitionJob({cmd:"list_partitions"},target,lun);};
  const backup = async (row: {name:string;first_lba:number;last_lba:number}) => {
    if (!target || !parts || busy || picking.current) return;
    picking.current=true; setChoosing(true);
    const lun = parts.lun;
    try {
      const path = await pickSavePath(`${row.name.replace(/[^a-zA-Z0-9_.-]/g,'_')}.img`);
      if (path && !partitionJob({cmd:"read_partition",path,first_lba:row.first_lba,num_sectors:row.last_lba-row.first_lba+1,label:row.name},target,lun,row)) toast(false,"Device or table changed","Read the partition table again before choosing a backup destination.");
    } catch(error) {toast(false,"Could not start backup",String(error));}
    finally {picking.current=false;setChoosing(false);}
  };
  return <div className="page">{state.source === "sim" ? <section className="card pad"><h2>Partition access requires the native application</h2><p>This browser preview has no USB access. In the native app, load Firehose on Devices and read or back up partitions here without choosing a flash plan.</p></section> : !available ? <section className="card pad"><h2>Load Firehose to read partitions</h2><p>No flash plan is needed. Connect a programmer on Devices, then return here to inspect storage or make backups.</p><Button onClick={()=>dispatch({type:"page",page:"device"})}>Go to devices</Button></section> : parts?.vip ? <section className="card pad"><h2>Partition browsing unavailable in this VIP session</h2><p>The signed digest plan restricts device commands. Use the reviewed XML workflow, or reconnect without VIP if your programmer supports it.</p></section> : <section className="card pad"><div className="job-heading"><div><h2>Partition table</h2><p>Target: {state.devices.find(d=>d.path === target)?.label} · USB {state.devices.find(d=>d.path === target)?.bus}:{state.devices.find(d=>d.path === target)?.devnum}</p><p>Reading the table and saving backups do not write to device storage.</p></div><Button disabled={busy || choosing} onClick={()=>refresh(parts?.lun ?? 0)}>Read / refresh table</Button></div><div className="device-actions"><label>LUN <select className="select" aria-label="Storage LUN" value={parts?.lun ?? 0} disabled={busy || choosing} onChange={e=>refresh(Number(e.target.value))}>{Array.from({length:parts?.luns || 1},(_,i)=><option key={i} value={i}>{i}</option>)}</select></label><input className="select" aria-label="Find partition" placeholder="Find a partition" value={filter} onChange={e=>setFilter(e.target.value)}/><span className="note">{parts ? `${parts.rows.length} partitions · ${parts.sector_size} bytes per sector` : "No table loaded yet"}</span></div>
      <div className="table-scroll"><table className="partition-table"><thead><tr><th>Partition</th><th>Size</th><th>Sector range</th><th>Backup</th></tr></thead><tbody>{parts?.rows.filter(row=>row.name.toLowerCase().includes(filter.toLowerCase())).map((row,i)=><tr key={`${row.first_lba}:${i}`}><td>{row.name}</td><td>{bytes((row.last_lba-row.first_lba+1)*parts.sector_size)}</td><td className="mono">{row.first_lba}–{row.last_lba}</td><td><Button variant="outlined" disabled={busy || choosing} onClick={()=>void backup(row)}>Save image…</Button></td></tr>)}</tbody></table></div>
      {parts && !parts.rows.length && <p>No partitions were returned on this LUN.</p>}</section>}</div>;
}

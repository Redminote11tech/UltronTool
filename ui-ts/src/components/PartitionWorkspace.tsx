import {useState} from "react";
import {ArrowDownToLine,FileUp,HardDrive,Search,RefreshCw} from "lucide-react";
import type {PartRow,State} from "../state/model";
import type {ImageInspection} from "../state/daemon";
import {imageWriteProblem} from "../state/partitionPolicy";
import {Button} from "./Button";
import {bytes} from "../lib/format";
export interface PartitionWorkspaceProps {
  parts:NonNullable<State["parts"]>; selected:PartRow|null; image:ImageInspection|null;
  device:string; busy:boolean; onSelect:(row:PartRow)=>void; onRefresh:(lun:number)=>void;
  onClearSelection:()=>void; onBackup:()=>void; onChooseImage:()=>void; onClearImage:()=>void; onReview:()=>void;
}
export function PartitionWorkspace({parts,selected,image,device,busy,onSelect,onRefresh,onClearSelection,onBackup,onChooseImage,onClearImage,onReview}:PartitionWorkspaceProps) {
  const [filter,setFilter]=useState("");
  const rows=parts.rows.filter(r=>r.name.toLowerCase().includes(filter.toLowerCase()));
  const sectors=selected ? selected.last_lba-selected.first_lba+1 : 0;
  const problem=image ? imageWriteProblem(image,parts.sector_size,sectors) : null;
  return <div className={`partition-workspace ${selected ? "has-selection" : ""}`}>
    <section className="partition-browser card" aria-label="Partition list">
      <div className="partition-toolbar"><label className="field-label">Storage unit (LUN)<select className="select" aria-label="Storage unit (LUN)" value={parts.lun} disabled={busy} onChange={e=>onRefresh(Number(e.target.value))}>{Array.from({length:parts.luns || 1},(_,i)=><option key={i} value={i}>LUN {i}</option>)}</select></label><Button variant="outlined" disabled={busy} onClick={()=>onRefresh(parts.lun)}><RefreshCw size={16}/>Refresh</Button></div>
      <label className="partition-search"><Search size={18}/><input aria-label="Find partition" placeholder="Find a partition" value={filter} onChange={e=>setFilter(e.target.value)}/></label>
      <div className="partition-list-scroll"><table className="partition-list-table"><thead><tr><th>Partition</th><th>Capacity</th></tr></thead><tbody>{rows.map((row,i)=><tr key={`${row.first_lba}:${i}`} className={selected?.first_lba===row.first_lba ? "selected" : ""}><td><button className="partition-pick" aria-label={`Select ${row.name}`} aria-pressed={selected?.first_lba===row.first_lba} disabled={busy} onClick={()=>onSelect(row)}><HardDrive size={17}/><span>{row.name}</span></button></td><td>{bytes((row.last_lba-row.first_lba+1)*parts.sector_size)}</td></tr>)}</tbody></table>{!rows.length && <p className="partition-empty">{parts.rows.length ? "No partitions match your search." : "No partitions found on this storage unit."}</p>}</div>
      <footer className="partition-list-footer">{rows.length} of {parts.rows.length} partitions · {device}</footer>
    </section>
    <aside className="partition-detail card pad" aria-label="Selected partition">{!selected ? <><HardDrive size={32}/><h2>Select a partition</h2><p>Choose a partition to save a backup or write an image. No XML is required.</p></> : <><Button className="partition-back" disabled={busy} onClick={onClearSelection}>Back to partitions</Button><div className="partition-detail-title"><span className="eyebrow">Selected partition</span><h2>{selected.name}</h2><p>{bytes(sectors*parts.sector_size)} · LUN {parts.lun}</p></div>
      <section className="partition-task"><h3>Back up</h3><p>Read this partition into a file on your computer.</p><Button variant="outlined" block disabled={busy} onClick={onBackup}><ArrowDownToLine size={18}/>Save backup…</Button></section>
      <section className="partition-task"><h3>Write an image</h3>{!image && <p>Choose a raw .img or .bin file for this partition.</p>}{image ? <><div className="image-selection"><b>{image.path.split('/').pop()}</b><span>{bytes(image.size)}</span></div>{problem ? <p className="inline-error" role="alert">{problem}</p> : <p className="note">Fits this partition. Review the destination before writing.</p>}<div className="partition-image-actions"><Button disabled={busy} onClick={onChooseImage}>Change file</Button><Button disabled={busy} onClick={onClearImage}>Clear</Button></div><Button variant="filled" block disabled={busy || !!problem} onClick={onReview}>Review write…</Button></> : <Button variant="filled" block disabled={busy} onClick={onChooseImage}><FileUp size={18}/>Choose image…</Button>}</section>
      <details className="partition-location"><summary>Partition location</summary><dl><dt>First sector</dt><dd>{selected.first_lba}</dd><dt>Last sector</dt><dd>{selected.last_lba}</dd><dt>Sector size</dt><dd>{parts.sector_size} bytes</dd></dl></details>
    </>}</aside>
  </div>;
}

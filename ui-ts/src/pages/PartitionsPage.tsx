import {useRef,useState} from "react";
import {useBus} from "../state/bus";
import type {PartRow} from "../state/model";
import type {ImageInspection} from "../state/daemon";
import {partitionSnapshot,snapshotCurrent,imageWriteProblem} from "../state/partitionPolicy";
import type {PartitionSnapshot} from "../state/partitionPolicy";
import {Button} from "../components/Button";
import {PartitionWorkspace} from "../components/PartitionWorkspace";
import {PartitionWriteReview} from "../components/PartitionWriteReview";
import {pickFiles,pickSavePath} from "../lib/tauri";
export function PartitionsPage() {
  const {state,dispatch,partitionJob,inspectImage,toast}=useBus();
  const current=useRef(state); current.current=state;
  const [selection,setSelection]=useState<{target:string;parts:typeof state.parts;row:PartRow}|null>(null);
  const [chosen,setChosen]=useState<{snapshot:PartitionSnapshot;image:ImageInspection}|null>(null);
  const [review,setReview]=useState(false);
  const [choosing,setChoosing]=useState(false);
  const picking=useRef(false);
  const parts=state.parts;
  const selected=selection?.target===state.selectedPath && selection.parts===parts ? selection.row : null;
  const image=chosen && selected && snapshotCurrent({...state,job:null},chosen.snapshot) && chosen.snapshot.row.first_lba===selected.first_lba ? chosen.image : null;
  const busy=choosing || !!state.job && !state.job.finished;
  const ready=state.source==="daemon" && state.session==="firehose_ready" && !!state.selectedPath && !state.daemonGone;
  const select=(row:PartRow)=>{if(state.job?.finished && !state.job.failed) dispatch({type:"jobDismiss"});setSelection({target:state.selectedPath!,parts,row});setChosen(null);setReview(false);};
  const refresh=(lun:number)=>{if(state.selectedPath) {setChosen(null);setReview(false);partitionJob({cmd:"list_partitions"},state.selectedPath,lun);}};
  const backup=async()=>{
    if(!selected || picking.current) return;
    const snapshot=partitionSnapshot(state,selected); if(!snapshot) return;
    picking.current=true;setChoosing(true);
    try {
      const path=await pickSavePath(`${selected.name.replace(/[^a-zA-Z0-9_.-]/g,'_')}.img`);
      if(path) {
        if(!snapshotCurrent(current.current,snapshot)) {toast(false,"Partition changed","Select the partition again before backing it up.");return;}
        partitionJob({cmd:"read_partition",path,first_lba:selected.first_lba,num_sectors:selected.last_lba-selected.first_lba+1,label:selected.name},snapshot.target,snapshot.lun,selected);
      }
    } catch(error) {toast(false,"Could not start backup",String(error));}
    finally {picking.current=false;setChoosing(false);}
  };
  const chooseImage=async()=>{
    if(!selected || picking.current) return;
    const snapshot=partitionSnapshot(state,selected); if(!snapshot) return;
    picking.current=true;setChoosing(true);setReview(false);
    try {
      const paths=await pickFiles({title:`Choose image for ${selected.name}`,filters:[{name:"Partition image",extensions:["img","bin"]}]});
      if(!paths.length) return;
      if(!snapshotCurrent(current.current,snapshot)) throw new Error("The device or table changed. Select the partition again.");
      const image=await inspectImage(paths[0]);
      if(image.path!==paths[0] || !snapshotCurrent({...current.current,job:null},snapshot)) throw new Error("The device or table changed during inspection. Select the partition again.");
      setChosen({snapshot,image});
    } catch(error) {toast(false,"Could not select image",String(error));}
    finally {picking.current=false;setChoosing(false);}
  };
  const valid=!!chosen && !!image && !busy && snapshotCurrent(state,chosen.snapshot) && !imageWriteProblem(chosen.image,chosen.snapshot.parts.sector_size,chosen.snapshot.row.last_lba-chosen.snapshot.row.first_lba+1);
  const write=()=>{
    if(!chosen || !valid) return;
    const {snapshot,image}=chosen;const {row}=snapshot;
    if(partitionJob({cmd:"write_partition",path:image.path,expected_size:image.size,first_lba:row.first_lba,max_sectors:row.last_lba-row.first_lba+1,label:row.name},snapshot.target,snapshot.lun,row)) {setReview(false);setChosen(null);}
  };
  const device=state.devices.find(d=>d.path===state.selectedPath);
  return <div className="page">{state.source==="sim" ? <section className="card pad empty-panel"><h2>Open the native app to access partitions</h2><p>The browser preview has no USB access. Load Firehose in the native app, then select a partition to back up or write an image.</p></section> : !ready ? <section className="card pad empty-panel"><h2>Connect Firehose first</h2><p>Choose and load a programmer on Devices, then return here. No XML is needed.</p><Button variant="filled" onClick={()=>dispatch({type:"page",page:"device"})}>Go to devices</Button></section> : parts?.vip ? <section className="card pad empty-panel"><h2>Partition actions unavailable in this VIP session</h2><p>The signed digest plan restricts device commands. Use the XML workflow, or reconnect without VIP if your programmer supports it.</p></section> : !parts ? <section className="card pad empty-panel"><h2>Read the partition table</h2><p>Load the partition names and capacities before choosing an action.</p><Button variant="filled" disabled={busy} onClick={()=>refresh(0)}>Read partitions</Button></section> : <PartitionWorkspace parts={parts} selected={selected} image={image} device={`${device?.label} · USB ${device?.bus}:${device?.devnum}`} busy={busy} onSelect={select} onClearSelection={()=>{setSelection(null);setChosen(null);setReview(false);}} onRefresh={refresh} onBackup={()=>void backup()} onChooseImage={()=>void chooseImage()} onClearImage={()=>setChosen(null)} onReview={()=>setReview(true)}/>}
    {chosen && <PartitionWriteReview open={review} valid={valid} row={chosen.snapshot.row} image={chosen.image} sectorSize={chosen.snapshot.parts.sector_size} lun={chosen.snapshot.lun} device={`${device?.label} · USB ${chosen.snapshot.bus}:${chosen.snapshot.devnum}`} onClose={()=>setReview(false)} onWrite={write}/>}
  </div>;
}

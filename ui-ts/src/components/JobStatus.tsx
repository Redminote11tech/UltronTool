import {CheckCircle2,TriangleAlert,X} from "lucide-react";
import {useBus} from "../state/bus";
import type {Job} from "../state/model";
import {Button} from "./Button";
import {Progress} from "./Progress";
import {bytes,rate} from "../lib/format";
export function OperationStatus({job,onCancel,onDismiss,onLog}:{job:Job|null;onCancel:()=>void;onDismiss:()=>void;onLog:()=>void}) {
  if(!job || job.finished && !job.failed && /^Inspecting/.test(job.title)) return null;
  if(job.finished) return <div className={`operation-result ${job.failed ? "failed" : ""}`} role="status">{job.failed ? <TriangleAlert size={18}/> : <CheckCircle2 size={18}/>}<span>{job.message || `${job.title}: ${job.failed ? "failed" : "complete"}`}</span><Button onClick={onLog}>View log</Button><button className="icon-button" aria-label="Dismiss result" onClick={onDismiss}><X size={18}/></button></div>;
  return <section className="card pad job-card" aria-live="polite"><div className="operation-heading"><div><h2>{job.title}</h2><p>{job.label}</p></div><Button variant="outlined" onClick={onCancel}>Cancel operation</Button></div><Progress value={job.fraction ?? 0} total={job.fraction===null ? 0 : 1}/><div className="prog-meta">{job.fraction!==null && <b>{(job.fraction*100).toFixed(1)}%</b>}{job.total>0 && <span>{bytes(job.value)} / {bytes(job.total)}</span>}{job.rate>0 && <span>{rate(job.rate)}</span>}</div></section>;
}
export function JobStatus() {
  const {state,dispatch,cancelFlash}=useBus();
  return <OperationStatus job={state.job} onCancel={cancelFlash} onDismiss={()=>dispatch({type:"jobDismiss"})} onLog={()=>dispatch({type:"page",page:"console"})}/>;
}

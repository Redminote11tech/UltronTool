import { useBus } from "../state/bus";
import { Button } from "./Button";
import { Progress } from "./Progress";
import { bytes, rate } from "../lib/format";
export function JobStatus() {
  const {state, cancelFlash} = useBus();
  const job = state.job;
  if (!job) return null;
  return <section className="card pad job-card" aria-live="polite"><h2>{job.title}</h2>
    {job.finished ? <p className={job.failed ? "banner-err" : "banner-ok"}>{job.failed ? "Failed" : "Complete"}: {job.message || "See the session log for details."}</p> : <><div className="job-heading"><p>{job.label}</p><Button variant="outlined" onClick={cancelFlash}>Cancel operation</Button></div><Progress value={job.fraction ?? 0} total={job.fraction === null ? 0 : 1} /><div className="prog-meta">{job.fraction !== null && <b>{(job.fraction * 100).toFixed(1)}%</b>}{job.total > 0 && <span>{bytes(job.value)} / {bytes(job.total)}</span>}{job.rate > 0 && <span>{rate(job.rate)}</span>}</div></>}
  </section>;
}

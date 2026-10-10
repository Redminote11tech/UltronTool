import type { State, PartRow } from "./model";
export function canLoadProgrammer(s: State): boolean {
  return s.source === "daemon" && !s.daemonGone && !!s.selectedPath && s.session === "needs_loader" && (!s.job || s.job.finished);
}
export function canReadPartition(s: State, target: string, lun: number, row?: PartRow): boolean {
  if (s.source !== "daemon" || s.daemonGone || s.session !== "firehose_ready" || s.selectedPath !== target || s.parts?.vip || s.job && !s.job.finished) return false;
  if (!Number.isSafeInteger(lun) || lun < 0 || lun >= (s.parts?.luns ?? 1)) return false;
  return !row || !!s.parts && s.parts.lun === lun && Number.isSafeInteger(row.first_lba) && Number.isSafeInteger(row.last_lba) && row.first_lba >= 0 && row.last_lba >= row.first_lba && Number.isSafeInteger(row.last_lba-row.first_lba+1) && s.parts.rows.some(p=>p.name === row.name && p.first_lba === row.first_lba && p.last_lba === row.last_lba);
}

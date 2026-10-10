import type { State, PartRow } from "./model";
export function canLoadProgrammer(s: State): boolean {
  return s.source === "daemon" && !s.daemonGone && !!s.selectedPath && (s.session === "disconnected" || s.session === "needs_loader") && (!s.job || s.job.finished);
}
export function canReadPartition(s: State, target: string, lun: number, row?: PartRow): boolean {
  if (s.source !== "daemon" || s.daemonGone || s.session !== "firehose_ready" || s.selectedPath !== target || s.parts?.vip || s.job && !s.job.finished) return false;
  if (!Number.isSafeInteger(lun) || lun < 0 || lun >= (s.parts?.luns ?? 1)) return false;
  return !row || !!s.parts && s.parts.lun === lun && Number.isSafeInteger(row.first_lba) && Number.isSafeInteger(row.last_lba) && row.first_lba >= 0 && row.last_lba >= row.first_lba && Number.isSafeInteger(row.last_lba-row.first_lba+1) && s.parts.rows.some(p=>p.name === row.name && p.first_lba === row.first_lba && p.last_lba === row.last_lba);
}

/** A selected programmer is sent with connect so Sahara never waits for a picker. */
export function programmerRequest(s: State, programmer: string, storage: string, skipInit: boolean, vipDir?: string): Record<string, unknown> | null {
  if (!canLoadProgrammer(s) || !programmer) return null;
  const dev = s.devices.find(d => d.path === s.selectedPath && d.mode === "qualcomm_edl");
  if (!dev) return null;
  const fields = {programmer, storage, skip_storage_init: skipInit, vip_dir: vipDir};
  return s.session === "disconnected"
    ? {cmd: "connect", target_path: dev.path, bus: dev.bus, devnum: dev.devnum, ...fields}
    : {cmd: "upload_loader", bus: dev.bus, devnum: dev.devnum, ...fields};
}

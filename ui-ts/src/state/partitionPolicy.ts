import type {State,PartRow} from "./model";
import type {ImageInspection} from "./daemon";
import {canReadPartition} from "./sessionPolicy.ts";
export interface PartitionSnapshot {target:string;bus:number;devnum:number;lun:number;row:PartRow;parts:NonNullable<State["parts"]>;configured:State["configured"]}
export function partitionSnapshot(s:State,row:PartRow):PartitionSnapshot|null {
  const dev=s.devices.find(d=>d.path===s.selectedPath);
  if(!dev || !s.parts || !canReadPartition(s,dev.path,s.parts.lun,row)) return null;
  return {target:dev.path,bus:dev.bus,devnum:dev.devnum,lun:s.parts.lun,row:{...row},parts:s.parts,configured:s.configured};
}
export function snapshotCurrent(s:State,p:PartitionSnapshot):boolean {
  const dev=s.devices.find(d=>d.path===p.target);
  return !!dev && dev.bus===p.bus && dev.devnum===p.devnum && s.parts===p.parts && s.configured===p.configured && canReadPartition(s,p.target,p.lun,p.row);
}
export function imageWriteProblem(image:ImageInspection,sectorSize:number,maxSectors:number):string|null {
  if(image.sparse) return "Android sparse image: expand it to a raw image before writing.";
  if(!Number.isSafeInteger(image.size) || image.size<=0) return "The image is empty or its size cannot be represented safely.";
  if(!Number.isSafeInteger(sectorSize) || sectorSize<=0 || !Number.isSafeInteger(maxSectors) || maxSectors<=0) return "Read a valid partition table before writing.";
  if(maxSectors>0xffffffff) return "This partition range is too large for the direct writer.";
  if(Math.ceil(image.size/sectorSize)>maxSectors) return "The image is larger than this partition. Nothing will be written.";
  return null;
}

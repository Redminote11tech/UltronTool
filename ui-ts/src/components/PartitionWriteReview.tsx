import {Modal} from "./Modal";
import {Button} from "./Button";
import {bytes} from "../lib/format";
import type {ImageInspection} from "../state/daemon";
import type {PartRow} from "../state/model";
export interface WriteReviewProps {open:boolean;valid:boolean;row:PartRow;image:ImageInspection;sectorSize:number;lun:number;device:string;onClose:()=>void;onWrite:()=>void}
export function PartitionWriteReview({open,valid,row,image,sectorSize,lun,device,onClose,onWrite}:WriteReviewProps) {
  const count=Math.ceil(image.size/sectorSize);
  return <Modal open={open} label={`Write image to ${row.name}`} onClose={onClose}><h3>Write image to {row.name}?</h3><p>This overwrites {bytes(count*sectorSize)} at the start of the selected partition. Back up any data you need first.</p><dl className="write-review-details"><dt>Device</dt><dd>{device}</dd><dt>Partition</dt><dd>{row.name} · LUN {lun}</dd><dt>Image</dt><dd className="mono">{image.path}</dd><dt>Image size</dt><dd>{bytes(image.size)}</dd><dt>Write range</dt><dd>Sectors {row.first_lba}–{row.first_lba+count-1}</dd></dl><p className="note">The final sector is zero-padded if needed. The rest of the partition is left as it is.</p>{!valid && <p className="inline-error" role="alert">The device, session or partition table changed. Close this review and choose the image again.</p>}<div className="modal-actions"><Button onClick={onClose}>Cancel</Button><Button variant="error" disabled={!valid} onClick={onWrite}>Write {row.name}</Button></div></Modal>;
}

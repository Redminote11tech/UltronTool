import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createInitial,reducer} from '../src/state/model.ts';
import {partitionSnapshot,snapshotCurrent,imageWriteProblem} from '../src/state/partitionPolicy.ts';
const row={name:'boot_a',first_lba:8,last_lba:15};
const state={...createInitial('daemon'),selectedPath:'A',session:'firehose_ready',devices:[{path:'A',mode:'qualcomm_edl',bus:5,devnum:34}],parts:{lun:0,luns:2,sector_size:512,vip:false,rows:[row]},configured:{storage:'ufs',skipInit:false,vipDir:''}};
test('a partition write review cannot survive a changed device, session or table',()=>{
  const snapshot=partitionSnapshot(state,row);
  assert.ok(snapshot);assert.equal(snapshotCurrent(state,snapshot),true);
  assert.equal(snapshotCurrent({...state,devices:[{...state.devices[0],devnum:35}]},snapshot),false);
  assert.equal(snapshotCurrent({...state,parts:{...state.parts}},snapshot),false);
  assert.equal(snapshotCurrent({...state,configured:{...state.configured}},snapshot),false);
  assert.equal(snapshotCurrent({...state,session:'disconnected'},snapshot),false);
  assert.equal(snapshotCurrent({...state,job:{finished:false}},snapshot),false);
  assert.equal(partitionSnapshot({...state,parts:{...state.parts,vip:true}},row),null);
});
test('image review checks real format, emptiness and rounded-up partition capacity',()=>{
  const img={ev:'image_info',path:'/boot.img',size:4096,sparse:false};
  assert.equal(imageWriteProblem(img,512,8),null);
  assert.match(imageWriteProblem({...img,size:4097},512,8),/larger/);
  assert.match(imageWriteProblem({...img,size:0},512,8),/empty/);
  assert.match(imageWriteProblem({...img,sparse:true},512,8),/sparse/);
  assert.match(imageWriteProblem({...img,size:Number.MAX_SAFE_INTEGER+1},512,8),/safely/);
  assert.match(imageWriteProblem(img,0,8),/valid/);
  assert.match(imageWriteProblem(img,512,0x100000000),/too large/);
});
test('dismissing a completed result preserves the log and cannot hide a running operation',()=>{
  const running=reducer(state,{type:'jobStart',title:'Writing boot_a',total:512});
  assert.equal(reducer(running,{type:'jobDismiss'}),running);
  const done=reducer(running,{type:'jobEnd',failed:false,message:'done'});
  const dismissed=reducer(done,{type:'jobDismiss'});
  assert.equal(dismissed.job,null);assert.deepEqual(dismissed.logs,done.logs);
});

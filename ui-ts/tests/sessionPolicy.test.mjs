import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createInitial} from '../src/state/model.ts';
import {canLoadProgrammer,canReadPartition,programmerRequest} from '../src/state/sessionPolicy.ts';
const row={name:'boot_a',first_lba:8,last_lba:15};
const s={...createInitial('daemon'),selectedPath:'A',session:'firehose_ready',parts:{lun:0,luns:2,vip:false,rows:[row]}};
test('loading a programmer does not depend on a rawprogram or flash plan',()=>{
  const loader={...s,session:'needs_loader',draft:{...s.draft,files:{}}};
  assert.equal(canLoadProgrammer(loader),true);
  assert.equal(canLoadProgrammer({...loader,session:'firehose_ready'}),false);
  assert.equal(canLoadProgrammer({...loader,daemonGone:'gone'}),false);
});
test('backups require the same target, LUN and partition range after the save picker',()=>{
  assert.equal(canReadPartition(s,'A',0,row),true);
  assert.equal(canReadPartition(s,'B',0,row),false);
  assert.equal(canReadPartition(s,'A',1,row),false);
  assert.equal(canReadPartition(s,'A',0,{...row,last_lba:16}),false);
  assert.equal(canReadPartition({...s,session:'needs_loader'},'A',0,row),false);
  assert.equal(canReadPartition({...s,parts:{...s.parts,vip:true}},'A',0,row),false);
  assert.equal(canReadPartition({...s,job:{finished:false}},'A',0,row),false);
});

test('the normal loader flow carries the programmer in the initial connect request',()=>{
  const device={path:'A',mode:'qualcomm_edl',bus:5,devnum:25};
  const fresh={...s,session:'disconnected',devices:[device]};
  const request=programmerRequest(fresh,'/loader.mbn','ufs',false);
  assert.equal(request.cmd,'connect');
  assert.equal(request.programmer,'/loader.mbn');
  assert.equal(request.target_path,'A');
  assert.equal(request.bus,5);
  assert.equal(request.devnum,25);
  assert.equal(programmerRequest({...fresh,session:'needs_loader'},'/loader.mbn','ufs',false).cmd,'upload_loader');
  assert.equal(programmerRequest({...fresh,devices:[]},'/loader.mbn','ufs',false),null);
  assert.equal(programmerRequest({...fresh,job:{finished:false}},'/loader.mbn','ufs',false),null);
});

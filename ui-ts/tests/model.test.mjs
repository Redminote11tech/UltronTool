import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initial, reducer } from '../src/state/model.ts';
const device = path => ({path,vid:0x05c6,pid:0x9008,bus:1,devnum:path==='A'?2:3,mode:'qualcomm_edl',label:'EDL',serial:'',manufacturer:'',product:''});
const selected = () => ({...structuredClone(initial),source:'daemon',devices:[device('A'),device('B')],selectedPath:'A',session:'firehose_ready',parts:{rows:[{name:'boot'}]},configured:{storage:'emmc',skipInit:false,vipDir:''}});
test('another USB device disappearing preserves the connected session and partition table', () => {
  const state = selected();
  const next = reducer(state,{type:'devRemove',path:'B'});
  assert.equal(next.session,'firehose_ready');
  assert.equal(next.selectedPath,'A');
  assert.equal(next.parts,state.parts);
});
test('removing the owned device invalidates its table and configured settings', () => {
  const next = reducer(selected(),{type:'devRemove',path:'A'});
  assert.equal(next.session,'disconnected');
  assert.equal(next.selectedPath,null);
  assert.equal(next.parts,null);
  assert.equal(next.configured,null);
});
test('selection cannot redirect a live session or outstanding job', () => {
  const connected = selected();
  assert.equal(reducer(connected,{type:'devSelect',path:'B'}),connected);
  const pending = reducer({...connected,session:'disconnected'},{type:'jobStart',title:'Connect A',total:0});
  assert.equal(reducer(pending,{type:'devSelect',path:'B'}),pending);
});
test('staged inputs survive navigation and an old chooser cannot populate another device', () => {
  let state = {...selected(),session:'disconnected',draft:{scope:'daemon:A',files:{rawprogram:{name:'A.xml',size:0,paths:['/A.xml']}},storage:'ufs',skipInit:false}};
  state = reducer(state,{type:'page',page:'console'});
  assert.equal(state.draft.files.rawprogram.name,'A.xml');
  state = reducer(state,{type:'devSelect',path:'B'});
  assert.deepEqual(state.draft.files,{});
  state = reducer(state,{type:'draftFiles',scope:'daemon:A',update:()=>({rawprogram:{name:'old',size:0,paths:['/old']}})});
  assert.deepEqual(state.draft.files,{});
});
test('backend death fails an admitted job even before the first progress event', () => {
  const state = reducer(selected(),{type:'jobStart',title:'Flash',total:0});
  const next = reducer(state,{type:'daemonGone',reason:'pipe closed'});
  assert.equal(next.job.finished,true); assert.equal(next.job.failed,true);
});
test('the configured backend storage replaces a rejected requested type', () => {
  const state = reducer(selected(),{type:'configured',storage:'emmc',skipInit:true,vipDir:'/signed'});
  assert.equal(state.draft.storage,'emmc'); assert.equal(state.draft.skipInit,true);
  assert.equal(state.configured.vipDir,'/signed');
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { progressSample } from '../src/state/progress.ts';
test('fraction-only progress remains visible and unknown progress stays unknown', () => {
  assert.equal(progressSample(null, {done:0,total:0,fraction:0.4,label:'configure'}, 1).fraction, .4);
  assert.equal(progressSample(null, {done:0,total:0,fraction:-1,label:'draining'}, 1).fraction, null);
});
test('rates do not cross image boundaries or counter resets', () => {
  const first = progressSample(null,{done:100,total:1000,fraction:.1,label:'boot'},1000);
  assert.equal(progressSample(first.sample,{done:200,total:1000,fraction:.2,label:'boot'},2000).rate,100);
  assert.equal(progressSample(first.sample,{done:100,total:1000,fraction:.1,label:'system'},2000).rate,0);
  assert.equal(progressSample(first.sample,{done:50,total:1000,fraction:.1,label:'boot'},2000).rate,0);
});

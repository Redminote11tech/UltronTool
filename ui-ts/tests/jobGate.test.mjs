import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JobGate, canSelectDevice } from '../src/state/jobGate.ts';
test('commands are locked before the first render or progress event', () => {
  const gate = new JobGate();
  const id = gate.begin('device-A');
  assert.equal(gate.begin('device-B'), null);
  assert.equal(gate.finish(id + 1), false);
  assert.equal(gate.busy, true);
  assert.equal(gate.target, 'device-A');
  assert.equal(gate.finish(id), true);
  assert.ok(gate.begin('device-B') > id);
});
test('selection cannot leave a connected or busy target', () => {
  assert.equal(canSelectDevice('A', 'B', 'firehose_ready', false), false);
  assert.equal(canSelectDevice('A', 'B', 'disconnected', true), false);
  assert.equal(canSelectDevice('A', 'B', 'disconnected', false), true);
});
test('reload attaches to an active request and advances future IDs', () => {
  const gate = new JobGate();
  gate.restore(41, 'device-A');
  assert.equal(gate.begin('device-B'), null);
  assert.equal(gate.finish(41), true);
  assert.equal(gate.begin('device-A'), 42);
});

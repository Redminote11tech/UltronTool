import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatLog } from '../src/lib/logExport.ts';
test('export retains timestamps, levels, multiline diagnostics and UTF-8', () => {
  assert.equal(formatLog([{at:0,level:'error',text:'failure\nUSB → gone'}]), '1970-01-01T00:00:00.000Z [ERROR] failure\nUSB → gone\n');
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { ReloadableRuntime } from '../lib/reloadable-runtime.js';

test('reloadable runtime reuses one instance for the same signature', async () => {
  const disposed = [];
  const manager = new ReloadableRuntime({
    dispose: async runtime => disposed.push(runtime.id),
  });
  let created = 0;
  const create = async () => ({ id: ++created });

  const first = await manager.acquire('config-a', create);
  const second = await manager.acquire('config-a', create);
  assert.equal(first.runtime, second.runtime);
  assert.equal(created, 1);

  await first.release();
  await second.release();
  assert.deepEqual(disposed, []);
  await manager.invalidate();
  assert.deepEqual(disposed, [1]);
});

test('configuration rotation drains the old runtime without interrupting its lease', async () => {
  const disposed = [];
  const manager = new ReloadableRuntime({
    dispose: async runtime => disposed.push(runtime.id),
  });

  const oldLease = await manager.acquire('config-a', async () => ({ id: 'old' }));
  const newLease = await manager.acquire('config-b', async () => ({ id: 'new' }));
  assert.equal(oldLease.runtime.id, 'old');
  assert.equal(newLease.runtime.id, 'new');
  assert.deepEqual(disposed, []);

  await oldLease.release();
  assert.deepEqual(disposed, ['old']);
  await newLease.release();
  await manager.invalidate();
  assert.deepEqual(disposed, ['old', 'new']);
});

test('a failed replacement keeps the current runtime available', async () => {
  const manager = new ReloadableRuntime();
  const original = await manager.acquire('config-a', async () => ({ id: 'stable' }));
  await assert.rejects(
    manager.acquire('config-b', async () => { throw new Error('replacement failed'); }),
    /replacement failed/,
  );
  const reused = await manager.acquire('config-a', async () => ({ id: 'unexpected' }));
  assert.equal(reused.runtime, original.runtime);
  await original.release();
  await reused.release();
  await manager.shutdown();
});

test('shutdown can wait for active leases to drain', async () => {
  const disposed = [];
  const manager = new ReloadableRuntime({
    dispose: async runtime => disposed.push(runtime.id),
  });
  const lease = await manager.acquire('config-a', async () => ({ id: 'active' }));
  let completed = false;
  const shutdown = manager.shutdown({ waitForActive: true }).then(() => { completed = true; });

  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false);
  assert.deepEqual(disposed, []);
  await lease.release();
  await shutdown;
  assert.equal(completed, true);
  assert.deepEqual(disposed, ['active']);
  await assert.rejects(
    manager.acquire('config-a', async () => ({ id: 'late' })),
    /shut down/,
  );
});

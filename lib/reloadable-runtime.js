/**
 * One reloadable, reference-counted runtime slot.
 *
 * A changed signature installs a new runtime for future calls while existing
 * calls keep their lease on the previous runtime until they settle. This keeps
 * hot configuration updates from disposing work that is already in flight.
 */
export class ReloadableRuntime {
  #current = null;
  #records = new Set();
  #lockTail = Promise.resolve();
  #closed = false;

  constructor({ dispose } = {}) {
    this.dispose = typeof dispose === 'function' ? dispose : async () => {};
  }

  async acquire(signature, create) {
    if (!String(signature || '').trim()) throw new Error('runtime signature required');
    if (typeof create !== 'function') throw new Error('runtime factory required');

    return this.#exclusive(async () => {
      if (this.#closed) throw new Error('runtime manager is shut down');

      if (!this.#current || this.#current.signature !== signature) {
        const runtime = await create();
        const next = {
          signature,
          runtime,
          active: 0,
          retiring: false,
          disposed: false,
          drain: null,
          resolveDrain: null,
        };
        next.drain = new Promise(resolve => { next.resolveDrain = resolve; });
        const previous = this.#current;
        this.#current = next;
        this.#records.add(next);
        if (previous) await this.#retire(previous);
      }

      const record = this.#current;
      record.active += 1;
      let released = false;
      return {
        runtime: record.runtime,
        release: async () => {
          if (released) return;
          released = true;
          await this.#exclusive(async () => {
            record.active = Math.max(0, record.active - 1);
            if (record.retiring && record.active === 0) await this.#disposeRecord(record);
          });
        },
      };
    });
  }

  async invalidate() {
    await this.#exclusive(async () => {
      const current = this.#current;
      this.#current = null;
      if (current) await this.#retire(current);
    });
  }

  async shutdown({ waitForActive = false } = {}) {
    let drains = [];
    await this.#exclusive(async () => {
      this.#closed = true;
      this.#current = null;
      for (const record of this.#records) await this.#retire(record);
      drains = [...this.#records].map(record => record.drain);
    });
    if (waitForActive) await Promise.all(drains);
  }

  async #retire(record) {
    if (record.retiring) return;
    record.retiring = true;
    if (record.active === 0) await this.#disposeRecord(record);
  }

  async #disposeRecord(record) {
    if (record.disposed) return;
    record.disposed = true;
    try {
      await this.dispose(record.runtime);
    } finally {
      this.#records.delete(record);
      record.resolveDrain?.();
    }
  }

  async #exclusive(operation) {
    const previous = this.#lockTail;
    let unlock;
    this.#lockTail = new Promise(resolve => { unlock = resolve; });
    await previous;
    try {
      return await operation();
    } finally {
      unlock();
    }
  }
}

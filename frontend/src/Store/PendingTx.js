const DB_NAME = "amaru-treasury-pending-txs";
const DB_VERSION = 1;
const STORE_NAME = "pending-txs";

const memoryDatabases = new Map();

const failMessage = (err) => {
  if (err && typeof err.message === "string") {
    return err.message;
  }
  if (typeof err === "string") {
    return err;
  }
  return "IndexedDB pending transaction store failed";
};

const hasIndexedDB = () =>
  typeof globalThis.indexedDB !== "undefined" &&
  globalThis.indexedDB !== null;

const cloneJson = (value) => {
  if (typeof globalThis.structuredClone === "function") {
    return globalThis.structuredClone(value);
  }
  return JSON.parse(JSON.stringify(value));
};

const normalizeEntry = (entry) => ({
  txid: entry.txid,
  intent: cloneJson(entry.intent),
  unsignedTxHex: entry.unsignedTxHex,
  scope: entry.scope,
  requiredSigners: Array.isArray(entry.requiredSigners)
    ? [...entry.requiredSigners]
    : [],
  invalidHereafter: entry.invalidHereafter ?? null,
  witnesses: { ...(entry.witnesses ?? {}) },
  savedAt: entry.savedAt,
  supersedes: entry.supersedes ?? null,
});

const memoryStore = () => {
  if (!memoryDatabases.has(DB_NAME)) {
    memoryDatabases.set(DB_NAME, new Map());
  }
  return memoryDatabases.get(DB_NAME);
};

const openDatabase = () =>
  new Promise((resolve, reject) => {
    if (!hasIndexedDB()) {
      resolve(null);
      return;
    }

    const request = globalThis.indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME, { keyPath: "txid" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () =>
      reject(new Error("IndexedDB pending transaction store upgrade blocked"));
  });

const withStore = async (mode, f) => {
  const db = await openDatabase();
  if (db === null) {
    let settled = false;
    let result;
    const finish = (value) => {
      settled = true;
      result = value;
    };
    await f(null, finish, (err) => {
      throw err;
    });
    return settled ? result : undefined;
  }

  return await new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, mode);
    const store = tx.objectStore(STORE_NAME);
    let settled = false;
    const finish = (value) => {
      settled = true;
      resolve(value);
    };
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
    tx.oncomplete = () => {
      if (!settled) {
        resolve(undefined);
      }
      db.close();
    };
    Promise.resolve(f(store, finish, reject)).catch(reject);
  });
};

const requestPromise = (request) =>
  new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });

const putEntry = async (entry) => {
  const normalized = normalizeEntry(entry);
  await withStore("readwrite", async (store) => {
    if (store === null) {
      memoryStore().set(normalized.txid, cloneJson(normalized));
      return;
    }
    await requestPromise(store.put(normalized));
  });
};

const getEntry = async (txid) =>
  await withStore("readonly", async (store, finish) => {
    if (store === null) {
      finish(cloneJson(memoryStore().get(txid) ?? null));
      return;
    }
    finish(await requestPromise(store.get(txid)));
  });

const listEntries = async () =>
  await withStore("readonly", async (store, finish) => {
    if (store === null) {
      finish(
        [...memoryStore().values()]
          .map(cloneJson)
          .sort((a, b) => a.txid.localeCompare(b.txid)),
      );
      return;
    }
    finish(await requestPromise(store.getAll()));
  });

const deleteEntry = async (txid) => {
  await withStore("readwrite", async (store) => {
    if (store === null) {
      memoryStore().delete(txid);
      return;
    }
    await requestPromise(store.delete(txid));
  });
};

const updateWitnesses = async (txid, update) => {
  await withStore("readwrite", async (store) => {
    if (store === null) {
      const current = memoryStore().get(txid);
      if (!current) {
        throw new Error(`pending transaction not found: ${txid}`);
      }
      const next = cloneJson(current);
      next.witnesses = update({ ...(next.witnesses ?? {}) });
      memoryStore().set(txid, next);
      return;
    }

    const current = await requestPromise(store.get(txid));
    if (!current) {
      throw new Error(`pending transaction not found: ${txid}`);
    }
    const next = normalizeEntry(current);
    next.witnesses = update({ ...(next.witnesses ?? {}) });
    await requestPromise(store.put(next));
  });
};

const runUnit = (promise, ok, fail) => {
  promise.then(
    () => ok({})(),
    (err) => fail(failMessage(err))(),
  );
};

const runValue = (promise, ok, fail) => {
  promise.then(
    (value) => ok(value ?? null)(),
    (err) => fail(failMessage(err))(),
  );
};

export const _put = (entry) => (ok) => (fail) => () =>
  runUnit(putEntry(entry), ok, fail);

export const _get = (txid) => (ok) => (fail) => () =>
  runValue(getEntry(txid), ok, fail);

export const _list = (ok) => (fail) => () =>
  runValue(listEntries(), ok, fail);

export const _deleteEntry = (txid) => (ok) => (fail) => () =>
  runUnit(deleteEntry(txid), ok, fail);

export const _addWitness = (txid) => (keyHash) => (witnessHex) => (ok) => (fail) => () =>
  runUnit(
    updateWitnesses(txid, (witnesses) => ({
      ...witnesses,
      [keyHash]: witnessHex,
    })),
    ok,
    fail,
  );

export const _removeWitness = (txid) => (keyHash) => (ok) => (fail) => () =>
  runUnit(
    updateWitnesses(txid, (witnesses) => {
      delete witnesses[keyHash];
      return witnesses;
    }),
    ok,
    fail,
  );

export const _clearAll = (ok) => (fail) => () =>
  runUnit(
    withStore("readwrite", async (store) => {
      if (store === null) {
        memoryStore().clear();
        return;
      }
      await requestPromise(store.clear());
    }),
    ok,
    fail,
  );

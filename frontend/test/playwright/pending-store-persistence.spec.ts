import { test, expect } from '@playwright/test';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';

const DB_NAME = 'amaru-treasury-pending-txs';
const DB_VERSION = 1;
const STORE_NAME = 'pending-txs';

type PendingTxEntry = {
  txid: string;
  intent: unknown;
  unsignedTxHex: string;
  scope: string;
  requiredSigners: string[];
  invalidHereafter: string | null;
  witnesses: Record<string, string>;
  savedAt: string;
  supersedes: string | null;
};

const entry: PendingTxEntry = {
  txid: 'txid-browser-reload',
  intent: { kind: 'swap', scope: 'core_development' },
  unsignedTxHex: 'deadbeefcafebabe',
  scope: 'core_development',
  requiredSigners: ['key-a', 'key-b'],
  invalidHereafter: '123456',
  witnesses: { 'key-a': 'witness-a-hex' },
  savedAt: '2026-06-12T20:00:00Z',
  supersedes: null,
};

test('pending tx IndexedDB entries survive page reload', async ({ page }) => {
  const server = await servePage();
  try {
    await page.goto(server.url);
    await page.evaluate(
      async ({ dbName, dbVersion, storeName, entry }) => {
        const deleteDatabase = async (name: string): Promise<void> => {
          await new Promise<void>((resolve, reject) => {
            const request = indexedDB.deleteDatabase(name);
            request.onsuccess = () => resolve();
            request.onerror = () => reject(request.error);
            request.onblocked = () =>
              reject(new Error('IndexedDB delete blocked'));
          });
        };
        const openDatabase = async (): Promise<IDBDatabase> =>
          await new Promise<IDBDatabase>((resolve, reject) => {
            const request = indexedDB.open(dbName, dbVersion);
            request.onupgradeneeded = () => {
              const db = request.result;
              if (!db.objectStoreNames.contains(storeName)) {
                db.createObjectStore(storeName, { keyPath: 'txid' });
              }
            };
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
            request.onblocked = () =>
              reject(new Error('IndexedDB open blocked'));
          });
        const putEntry = async (
          db: IDBDatabase,
          value: PendingTxEntry,
        ): Promise<void> => {
          await new Promise<void>((resolve, reject) => {
            const tx = db.transaction(storeName, 'readwrite');
            tx.objectStore(storeName).put(value);
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
            tx.onabort = () => reject(tx.error);
          });
        };

        await deleteDatabase(dbName);
        const db = await openDatabase();
        await putEntry(db, entry);
        db.close();
      },
      { dbName: DB_NAME, dbVersion: DB_VERSION, storeName: STORE_NAME, entry },
    );

    await page.reload();

    const persisted = await page.evaluate(
      async ({ dbName, dbVersion, storeName, txid }) => {
        const openDatabase = async (): Promise<IDBDatabase> =>
          await new Promise<IDBDatabase>((resolve, reject) => {
            const request = indexedDB.open(dbName, dbVersion);
            request.onupgradeneeded = () => {
              const db = request.result;
              if (!db.objectStoreNames.contains(storeName)) {
                db.createObjectStore(storeName, { keyPath: 'txid' });
              }
            };
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
            request.onblocked = () =>
              reject(new Error('IndexedDB open blocked'));
          });
        const getEntry = async (
          db: IDBDatabase,
        ): Promise<PendingTxEntry | undefined> =>
          await new Promise<PendingTxEntry | undefined>((resolve, reject) => {
            const tx = db.transaction(storeName, 'readonly');
            const request = tx.objectStore(storeName).get(txid);
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
          });

        const db = await openDatabase();
        const value = await getEntry(db);
        db.close();
        return value;
      },
      {
        dbName: DB_NAME,
        dbVersion: DB_VERSION,
        storeName: STORE_NAME,
        txid: entry.txid,
      },
    );

    expect(persisted).toEqual(entry);
  } finally {
    await server.close();
  }
});

async function servePage(): Promise<{ url: string; close: () => Promise<void> }> {
  const server: Server = createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end('<!doctype html><title>pending store persistence</title>');
  });

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });

  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}/`,
    close:
      () =>
        new Promise<void>((resolve, reject) => {
          server.close((err) => {
            if (err) {
              reject(err);
            } else {
              resolve();
            }
          });
        }),
  };
}

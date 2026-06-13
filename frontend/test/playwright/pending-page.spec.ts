import { test, expect, type Page } from '@playwright/test';
import { Buffer } from 'node:buffer';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';

const DB_NAME = 'amaru-treasury-pending-txs';
const DB_VERSION = 1;
const STORE_NAME = 'pending-txs';
const DIST_ROOT = path.join(process.cwd(), 'dist');
const CURRENT_SLOT = 1_200;
const PASTED_WITNESS = 'pasted-witness-b-hex';
const UPLOADED_REJECTED_WITNESS = 'uploaded-rejected-witness-c-hex';
const REJECTED_REASON = 'witness does not match any required signer';

type GraphValueSummary = {
  lovelace: number;
  assets: Record<string, Record<string, number>>;
};

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

const graphValue = (lovelace: number): GraphValueSummary => ({
  lovelace,
  assets: {},
});

const pendingEntries: PendingTxEntry[] = [
  {
    txid: 'tx-active-001',
    intent: {
      kind: 'swap',
      swapGraphEffect: {
        spends: [
          {
            txIn: 'active-input#0',
            scope: 'core_development',
            role: 'treasury',
            value: graphValue(2_500_000),
            resolved: true,
          },
        ],
        produces: [
          {
            index: 0,
            address: 'addr_test1pendingoutput',
            scope: 'core_development',
            role: 'treasury',
            value: graphValue(2_000_000),
            datum: null,
            projectedDatum: null,
          },
        ],
      },
    },
    unsignedTxHex: 'deadbeef-active',
    scope: 'core_development',
    requiredSigners: ['signer-a', 'signer-b'],
    invalidHereafter: '1500',
    witnesses: { 'signer-a': 'witness-a-hex' },
    savedAt: '2026-06-13T09:00:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-expired-001',
    intent: { kind: 'disburse' },
    unsignedTxHex: 'deadbeef-expired',
    scope: 'middleware',
    requiredSigners: ['signer-c'],
    invalidHereafter: '1100',
    witnesses: {},
    savedAt: '2026-06-13T08:00:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-history-001',
    intent: { kind: 'swap' },
    unsignedTxHex: 'deadbeef-history',
    scope: 'ops_and_use_cases',
    requiredSigners: ['signer-d'],
    invalidHereafter: '1800',
    witnesses: { 'signer-d': 'witness-d-hex' },
    savedAt: '2026-06-13T07:00:00Z',
    supersedes: 'tx-previous-001',
  },
];

const witnessVerificationEntry: PendingTxEntry = {
  txid: 'tx-witness-001',
  intent: { kind: 'swap' },
  unsignedTxHex: 'unsigned-witness-tx-hex',
  scope: 'core_development',
  requiredSigners: ['signer-a', 'signer-b', 'signer-c'],
  invalidHereafter: '1500',
  witnesses: { 'signer-a': 'witness-a-hex' },
  savedAt: '2026-06-13T10:00:00Z',
  supersedes: null,
};

test('pending page lists local entries by lane and opens details', async ({
  page,
}) => {
  const server = await serveDist();
  try {
    await page.goto(`${server.url}/`);
    await seedPendingEntries(page, pendingEntries);

    await page.goto(`${server.url}/pending`);

    await expect(
      page.getByRole('link', { name: 'Pending co-signing' }),
    ).toBeVisible();
    await expect(
      page.getByRole('heading', { name: 'Pending' }),
    ).toBeVisible();

    const activeLane = page.getByRole('region', {
      name: 'Active pending transactions',
    });
    const expiredLane = page.getByRole('region', {
      name: 'Expired pending transactions',
    });
    const historyLane = page.getByRole('region', {
      name: 'Pending transaction history',
    });

    await expect(activeLane).toContainText('tx-active-001');
    await expect(expiredLane).toContainText('tx-expired-001');
    await expect(historyLane).toContainText('tx-history-001');

    await expect(
      activeLane
        .locator('.signer-chip[data-active="true"]')
        .filter({ hasText: 'signer-a' }),
    ).toBeVisible();
    await expect(
      activeLane
        .locator('.signer-chip[data-active="false"]')
        .filter({ hasText: 'signer-b' }),
    ).toBeVisible();

    await activeLane
      .getByRole('button', {
        name: 'View pending transaction tx-active-001',
      })
      .click();

    const detail = page.getByRole('region', {
      name: 'Pending transaction detail',
    });
    await expect(
      detail.getByRole('heading', { name: 'Witness roster' }),
    ).toBeVisible();
    await expect(detail).toContainText('signer-a');
    await expect(detail).toContainText('Collected');
    await expect(detail).toContainText('signer-b');
    await expect(detail).toContainText('Missing');
    await expect(detail.getByRole('heading', { name: 'Inputs' })).toBeVisible();
    await expect(detail).toContainText('active-input#0');
    await expect(
      detail.getByRole('heading', { name: 'Outputs' }),
    ).toBeVisible();
    await expect(detail).toContainText('addr_test1pendingoutput');
  } finally {
    await server.close();
  }
});

test('pending page verifies pasted and uploaded witnesses through backend', async ({
  page,
}) => {
  const server = await serveDist();
  const verifyRequests: Record<string, unknown>[] = [];
  try {
    await page.goto(`${server.url}/`);
    await seedPendingEntries(page, [witnessVerificationEntry]);

    await page.route('**/v1/verify-witness', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON() as Record<string, unknown>;
      verifyRequests.push(body);

      expect(Object.keys(body).sort()).toEqual(['unsignedTx', 'witness']);
      expect(body.unsignedTx).toBe(witnessVerificationEntry.unsignedTxHex);

      if (body.witness === PASTED_WITNESS) {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            ok: true,
            signerKeyHash: 'signer-b',
            reason: null,
          }),
        });
        return;
      }

      if (body.witness === UPLOADED_REJECTED_WITNESS) {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            ok: false,
            signerKeyHash: null,
            reason: REJECTED_REASON,
          }),
        });
        return;
      }

      await route.fulfill({
        status: 400,
        contentType: 'application/json',
        body: JSON.stringify({
          ok: false,
          signerKeyHash: null,
          reason: 'unexpected witness',
        }),
      });
    });

    await page.goto(`${server.url}/pending`);

    const activeLane = page.getByRole('region', {
      name: 'Active pending transactions',
    });
    await activeLane
      .getByRole('button', {
        name: 'View pending transaction tx-witness-001',
      })
      .click();

    const detail = page.getByRole('region', {
      name: 'Pending transaction detail',
    });
    const witnessBox = detail.getByLabel('Witness hex');

    await witnessBox.fill(PASTED_WITNESS);
    await detail.getByRole('button', { name: 'Verify witness' }).click();

    await expect(detail).toContainText('Witness accepted for signer-b');
    await expect(
      detail
        .locator('.pending-roster__row[data-active="true"]')
        .filter({ hasText: 'signer-b' }),
    ).toContainText('Collected');
    await expect(
      page
        .locator('.signer-chip[data-active="true"]')
        .filter({ hasText: 'signer-b' }),
    ).toContainText('Collected');

    const storedAfterPaste = await getPendingEntry(
      page,
      witnessVerificationEntry.txid,
    );
    expect(storedAfterPaste?.witnesses['signer-a']).toBe('witness-a-hex');
    expect(storedAfterPaste?.witnesses['signer-b']).toBe(PASTED_WITNESS);
    expect(storedAfterPaste?.witnesses['signer-c']).toBeUndefined();

    await detail.getByLabel('Witness file').setInputFiles({
      name: 'rejected.witness',
      mimeType: 'text/plain',
      buffer: Buffer.from(UPLOADED_REJECTED_WITNESS, 'utf8'),
    });
    await expect(witnessBox).toHaveValue(UPLOADED_REJECTED_WITNESS);
    await detail.getByRole('button', { name: 'Verify witness' }).click();

    await expect(detail).toContainText(REJECTED_REASON);
    await expect(
      detail
        .locator('.pending-roster__row[data-active="false"]')
        .filter({ hasText: 'signer-c' }),
    ).toContainText('Missing');

    const storedAfterReject = await getPendingEntry(
      page,
      witnessVerificationEntry.txid,
    );
    expect(storedAfterReject?.witnesses['signer-b']).toBe(PASTED_WITNESS);
    expect(storedAfterReject?.witnesses['signer-c']).toBeUndefined();
    expect(Object.values(storedAfterReject?.witnesses ?? {})).not.toContain(
      UPLOADED_REJECTED_WITNESS,
    );

    expect(verifyRequests).toEqual([
      {
        unsignedTx: witnessVerificationEntry.unsignedTxHex,
        witness: PASTED_WITNESS,
      },
      {
        unsignedTx: witnessVerificationEntry.unsignedTxHex,
        witness: UPLOADED_REJECTED_WITNESS,
      },
    ]);
  } finally {
    await server.close();
  }
});

async function seedPendingEntries(
  page: Page,
  entries: PendingTxEntry[],
): Promise<void> {
  await page.evaluate(
    async ({ dbName, dbVersion, storeName, entries }) => {
      const deleteDatabase = async (name: string): Promise<void> => {
        await new Promise<void>((resolve, reject) => {
          const request = indexedDB.deleteDatabase(name);
          request.onsuccess = () => resolve();
          request.onerror = () => reject(request.error);
          request.onblocked = () =>
            reject(new Error('IndexedDB pending store delete blocked'));
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
            reject(new Error('IndexedDB pending store open blocked'));
        });

      const putEntries = async (db: IDBDatabase): Promise<void> => {
        await new Promise<void>((resolve, reject) => {
          const tx = db.transaction(storeName, 'readwrite');
          const store = tx.objectStore(storeName);
          for (const entry of entries) {
            store.put(entry);
          }
          tx.oncomplete = () => resolve();
          tx.onerror = () => reject(tx.error);
          tx.onabort = () => reject(tx.error);
        });
      };

      await deleteDatabase(dbName);
      const db = await openDatabase();
      await putEntries(db);
      db.close();
    },
    { dbName: DB_NAME, dbVersion: DB_VERSION, storeName: STORE_NAME, entries },
  );
}

async function getPendingEntry(
  page: Page,
  txid: string,
): Promise<PendingTxEntry | null> {
  return await page.evaluate(
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
            reject(new Error('IndexedDB pending store open blocked'));
        });

      const db = await openDatabase();
      try {
        return await new Promise<PendingTxEntry | null>(
          (resolve, reject) => {
            const tx = db.transaction(storeName, 'readonly');
            const request = tx.objectStore(storeName).get(txid);
            request.onsuccess = () =>
              resolve((request.result ?? null) as PendingTxEntry | null);
            request.onerror = () => reject(request.error);
            tx.onabort = () => reject(tx.error);
          },
        );
      } finally {
        db.close();
      }
    },
    { dbName: DB_NAME, dbVersion: DB_VERSION, storeName: STORE_NAME, txid },
  );
}

async function serveDist(): Promise<{
  url: string;
  close: () => Promise<void>;
}> {
  const server: Server = createServer((req, res) => {
    void handleRequest(req.url ?? '/', res);
  });

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });

  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}`,
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

async function handleRequest(
  rawUrl: string,
  res: import('node:http').ServerResponse,
): Promise<void> {
  const url = new URL(rawUrl, 'http://127.0.0.1');
  if (url.pathname === '/v1/tip') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ slot: CURRENT_SLOT }));
    return;
  }
  if (url.pathname.startsWith('/v1/')) {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not mocked in pending page test' }));
    return;
  }

  const requested = url.pathname === '/' ? '/index.html' : url.pathname;
  const candidate = safeDistPath(requested);
  const filePath = await existingFile(candidate ?? '', path.join(DIST_ROOT, 'index.html'));
  res.writeHead(200, { 'content-type': contentType(filePath) });
  createReadStream(filePath).pipe(res);
}

function safeDistPath(pathname: string): string | null {
  const relative = pathname.replace(/^\/+/, '');
  const candidate = path.normalize(path.join(DIST_ROOT, relative));
  if (!candidate.startsWith(DIST_ROOT)) {
    return null;
  }
  return candidate;
}

async function existingFile(
  candidate: string,
  fallback: string,
): Promise<string> {
  try {
    const info = await stat(candidate);
    return info.isFile() ? candidate : fallback;
  } catch {
    return fallback;
  }
}

function contentType(filePath: string): string {
  switch (path.extname(filePath)) {
    case '.css':
      return 'text/css; charset=utf-8';
    case '.js':
      return 'text/javascript; charset=utf-8';
    case '.svg':
      return 'image/svg+xml';
    case '.json':
      return 'application/json';
    case '.html':
    default:
      return 'text/html; charset=utf-8';
  }
}

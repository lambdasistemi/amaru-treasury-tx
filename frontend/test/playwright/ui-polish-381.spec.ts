import { test, expect, type Page } from '@playwright/test';
import { createReadStream } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { stat } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';

const DB_NAME = 'amaru-treasury-pending-txs';
const DB_VERSION = 1;
const STORE_NAME = 'pending-txs';
const DIST_ROOT = path.join(process.cwd(), 'dist');
const CURRENT_SLOT = 1_200;
const SCREENSHOT_PHASE = process.env.UI_POLISH_381_PHASE;

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

type RectSnapshot = {
  label: string;
  left: number;
  right: number;
  top: number;
  bottom: number;
  width: number;
  height: number;
};

const viewports = [
  { name: 'desktop-1280', width: 1280, height: 900 },
  { name: 'mobile-390', width: 390, height: 844 },
] as const;

const graphValue = (lovelace: number): unknown => ({
  lovelace,
  assets: {},
});

const pendingEntries: PendingTxEntry[] = [
  {
    txid: 'tx-active-ready-381-0123456789abcdef0123456789abcdef',
    intent: {
      kind: 'swap',
      buildEndpoint: '/v1/build/swap',
      buildRequest: {
        network: 'mainnet',
        scope: 'core_development',
        swap: {
          from: { policy: '', asset: '', quantity: '4500000' },
          to: { policy: 'policy-381', asset: 'asset-381' },
          route: { pool: 'pool1ui381', minimumReceived: '42' },
        },
      },
      swapGraphEffect: {
        spends: [
          {
            txIn:
              'active-ready-input-381-0123456789abcdef0123456789abcdef#0',
            scope: 'core_development',
            role: 'treasury',
            value: graphValue(4_500_000),
            resolved: true,
          },
        ],
        produces: [
          {
            index: 0,
            address:
              'addr1qx381populatedoutput0000000000000000000000000000000',
            scope: 'core_development',
            role: 'treasury',
            value: graphValue(4_000_000),
            datum: null,
            projectedDatum: null,
          },
        ],
      },
    },
    unsignedTxHex: 'deadbeef-ready-381',
    scope: 'core_development',
    requiredSigners: [
      'signer-core-development-381-aaaaaaaaaaaaaaaa',
      'signer-middleware-381-bbbbbbbbbbbbbbbb',
    ],
    invalidHereafter: '1900',
    witnesses: {
      'signer-core-development-381-aaaaaaaaaaaaaaaa':
        'witness-core-381-hex',
      'signer-middleware-381-bbbbbbbbbbbbbbbb':
        'witness-middleware-381-hex',
    },
    savedAt: '2026-06-13T12:00:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-active-missing-381-0123456789abcdef0123456789abcdef',
    intent: { kind: 'swap' },
    unsignedTxHex: 'deadbeef-missing-381',
    scope: 'middleware',
    requiredSigners: [
      'signer-network-compliance-381-cccccccccccccccc',
      'signer-ops-and-use-cases-381-dddddddddddddddd',
    ],
    invalidHereafter: '1850',
    witnesses: {
      'signer-network-compliance-381-cccccccccccccccc':
        'witness-network-381-hex',
    },
    savedAt: '2026-06-13T12:05:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-expired-381-0123456789abcdef0123456789abcdef',
    intent: { kind: 'disburse' },
    unsignedTxHex: 'deadbeef-expired-381',
    scope: 'network_compliance',
    requiredSigners: ['signer-expired-381-eeeeeeeeeeeeeeee'],
    invalidHereafter: '950',
    witnesses: {
      'signer-expired-381-eeeeeeeeeeeeeeee':
        'witness-expired-381-hex',
    },
    savedAt: '2026-06-13T11:00:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-history-381-0123456789abcdef0123456789abcdef',
    intent: { kind: 'reorganize' },
    unsignedTxHex: 'deadbeef-history-381',
    scope: 'ops_and_use_cases',
    requiredSigners: ['signer-history-381-ffffffffffffffff'],
    invalidHereafter: '1800',
    witnesses: {
      'signer-history-381-ffffffffffffffff':
        'witness-history-381-hex',
    },
    savedAt: '2026-06-13T10:00:00Z',
    supersedes: 'tx-older-history-381-0123456789abcdef0123456789abcdef',
  },
];

let localServer: { url: string; close: () => Promise<void> } | null = null;
let baseUrl = '';

test.beforeAll(async () => {
  localServer = await serveDist();
  baseUrl = localServer.url;
});

test.afterAll(async () => {
  if (localServer) {
    await localServer.close();
  }
});

for (const viewport of viewports) {
  test(`/operate controls stay in bounds @ ${viewport.name}`, async ({
    page,
  }) => {
    await page.setViewportSize({
      width: viewport.width,
      height: viewport.height,
    });
    await page.goto(`${baseUrl}/operate`);
    await page.waitForSelector('.build-layout', { timeout: 15_000 });

    await page
      .locator('#operate-signers-picker .signer-chip')
      .first()
      .click();

    await maybeScreenshot(page, 'operate', viewport.name);
    await assertNoHorizontalOverflow(page, `/operate ${viewport.name}`);
    await assertControlsWithinViewport(
      page,
      [
        '.operate-progress button',
        '.segmented button',
        '.scope-picker button',
        '#operate-signers-picker button',
        '.preview-tabs button',
        '.preview-card .btn',
      ].join(', '),
      `/operate ${viewport.name}`,
    );
    await assertControlsDoNotOverlap(
      page,
      [
        '.operate-progress button',
        '.segmented button',
        '.scope-picker button',
        '#operate-signers-picker button',
        '.preview-tabs button',
        '.preview-card .btn',
      ].join(', '),
      `/operate ${viewport.name}`,
    );
  });

  test(`/pending populated controls stay in bounds @ ${viewport.name}`, async ({
    page,
  }) => {
    await page.setViewportSize({
      width: viewport.width,
      height: viewport.height,
    });
    await page.goto(`${baseUrl}/`);
    await seedPendingEntries(page, pendingEntries);

    await page.goto(`${baseUrl}/pending`);
    await page.waitForSelector('.pending-layout', { timeout: 15_000 });

    const activeLane = page.getByRole('region', {
      name: 'Active pending transactions',
    });
    await expect(activeLane).toContainText(pendingEntries[0].txid);
    await expect(
      page.getByRole('region', { name: 'Expired pending transactions' }),
    ).toContainText(pendingEntries[2].txid);
    await expect(
      page.getByRole('region', { name: 'Pending transaction history' }),
    ).toContainText(pendingEntries[3].txid);

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${pendingEntries[0].txid}`,
      })
      .click();

    const detail = page.getByRole('region', {
      name: 'Pending transaction detail',
    });
    await detail.getByLabel('Witness hex').fill(
      'witness-extra-381-0123456789abcdef0123456789abcdef',
    );

    await expect(
      detail.getByRole('button', { name: 'Verify witness' }),
    ).toBeEnabled();
    await expect(
      detail.getByRole('button', { name: 'Submit transaction' }),
    ).toBeEnabled();
    await expect(
      detail.getByRole('button', { name: 'Rebuild transaction' }),
    ).toBeEnabled();

    await maybeScreenshot(page, 'pending', viewport.name);
    await assertNoHorizontalOverflow(page, `/pending ${viewport.name}`);
    await assertControlsWithinViewport(
      page,
      [
        '.pending-summary > *',
        '.pending-entry-card__button',
        '.pending-entry-card .signer-chip',
        '.pending-detail button',
        '.pending-detail input',
        '.pending-detail textarea',
      ].join(', '),
      `/pending ${viewport.name}`,
    );
    await assertControlsDoNotOverlap(
      page,
      [
        '.pending-entry-card__button',
        '.pending-detail button',
        '.pending-detail input',
        '.pending-detail textarea',
      ].join(', '),
      `/pending ${viewport.name}`,
    );
  });
}

async function assertNoHorizontalOverflow(
  page: Page,
  label: string,
): Promise<void> {
  const metrics = await page.evaluate(() => ({
    clientWidth: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
  }));
  expect(
    metrics.scrollWidth,
    `${label}: document horizontal overflow`,
  ).toBeLessThanOrEqual(metrics.clientWidth);
}

async function assertControlsWithinViewport(
  page: Page,
  selector: string,
  label: string,
): Promise<void> {
  const snapshot = await controlSnapshot(page, selector);
  expect(snapshot.rects.length, `${label}: controls found`).toBeGreaterThan(0);
  for (const rect of snapshot.rects) {
    expect(rect.width, `${label}: ${rect.label} width`).toBeGreaterThan(0);
    expect(rect.height, `${label}: ${rect.label} height`).toBeGreaterThan(0);
    expect(rect.left, `${label}: ${rect.label} left edge`).toBeGreaterThanOrEqual(
      -0.5,
    );
    expect(rect.right, `${label}: ${rect.label} right edge`).toBeLessThanOrEqual(
      snapshot.clientWidth + 0.5,
    );
  }
}

async function assertControlsDoNotOverlap(
  page: Page,
  selector: string,
  label: string,
): Promise<void> {
  const snapshot = await controlSnapshot(page, selector);
  for (let i = 0; i < snapshot.rects.length; i += 1) {
    for (let j = i + 1; j < snapshot.rects.length; j += 1) {
      const a = snapshot.rects[i];
      const b = snapshot.rects[j];
      const overlapX = Math.min(a.right, b.right) - Math.max(a.left, b.left);
      const overlapY =
        Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
      expect(
        overlapX > 1 && overlapY > 1,
        `${label}: ${a.label} overlaps ${b.label}`,
      ).toBe(false);
    }
  }
}

async function controlSnapshot(
  page: Page,
  selector: string,
): Promise<{ clientWidth: number; rects: RectSnapshot[] }> {
  return await page.evaluate((selectorArg) => {
    const clientWidth = document.documentElement.clientWidth;
    const rects = Array.from(document.querySelectorAll(selectorArg))
      .filter((el) => {
        const style = window.getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        return (
          style.visibility !== 'hidden' &&
          style.display !== 'none' &&
          rect.width > 0 &&
          rect.height > 0
        );
      })
      .map((el, index) => {
        const rect = el.getBoundingClientRect();
        const text = (el.textContent ?? '').replace(/\s+/g, ' ').trim();
        const label =
          el.getAttribute('aria-label') ||
          el.getAttribute('name') ||
          text ||
          `${el.tagName.toLowerCase()}-${index}`;
        return {
          label,
          left: rect.left,
          right: rect.right,
          top: rect.top,
          bottom: rect.bottom,
          width: rect.width,
          height: rect.height,
        };
      });
    return { clientWidth, rects };
  }, selector);
}

async function maybeScreenshot(
  page: Page,
  routeName: 'operate' | 'pending',
  viewportName: string,
): Promise<void> {
  if (!SCREENSHOT_PHASE) {
    return;
  }
  const dir = path.join(
    process.cwd(),
    'test',
    'ui-review',
    '381',
    SCREENSHOT_PHASE,
  );
  await mkdir(dir, { recursive: true });
  await page.screenshot({
    path: path.join(
      dir,
      `381-${SCREENSHOT_PHASE}-${routeName}-${viewportName}.png`,
    ),
    fullPage: true,
  });
}

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
      for (const entry of entries) {
        await putEntry(db, entry);
      }
      db.close();
    },
    { dbName: DB_NAME, dbVersion: DB_VERSION, storeName: STORE_NAME, entries },
  );
}

async function serveDist(): Promise<{ url: string; close: () => Promise<void> }> {
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
    res.end(JSON.stringify({ error: 'not mocked in ui-polish-381' }));
    return;
  }

  const requested = url.pathname === '/' ? '/index.html' : url.pathname;
  const candidate = safeDistPath(requested);
  const filePath = await existingFile(
    candidate ?? '',
    path.join(DIST_ROOT, 'index.html'),
  );
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

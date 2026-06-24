import { test, expect, type Page } from '@playwright/test';
import { createReadStream } from 'node:fs';
import { mkdir, stat } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';

const CURRENT_SLOT = 1_200;
const SINGLE_CBOR_HEX = 'unsigned-rerate-single-cbor-hex';
const SINGLE_TXID = 'tx-rerate-single-001';
const SINGLE_REQUIRED_SIGNERS = [
  'rerate-signer-a',
  'rerate-signer-b',
];
const SINGLE_INVALID_HEREAFTER = 1_950;
const SPLIT_REASON = 'selected orders exceed the single transaction budget';
const WALLET_TX_IN =
  'walletfuel000000000000000000000000000000000000000000000000000001#0';
const COLLATERAL_TX_IN =
  'collateral000000000000000000000000000000000000000000000000000001#1';

const FRONTEND_ROOT =
  path.basename(process.cwd()) === 'frontend'
    ? process.cwd()
    : path.join(process.cwd(), 'frontend');
const DIST_ROOT = path.resolve(
  process.env.AMARU_TREASURY_DIST ?? path.join(FRONTEND_ROOT, 'dist'),
);
const UI_REVIEW_ROOT = path.join(FRONTEND_ROOT, 'test', 'ui-review', '402');

type PendingOutRef = {
  txId: string;
  ix: number;
};

type PendingSwapOrder = {
  outref: PendingOutRef;
  lovelaceIn: number;
  minUsdmOut: number;
  sundaeFeeLovelace: number;
};

type PendingScope = {
  scope: string;
  orders: PendingSwapOrder[];
};

type PendingResponse = {
  scope: string;
  entries: PendingScope[];
};

const pendingOrders: PendingSwapOrder[] = [
  {
    outref: { txId: 'rerate-order-a', ix: 0 },
    lovelaceIn: 12_500_000,
    minUsdmOut: 5_100_000,
    sundaeFeeLovelace: 2_000_000,
  },
  {
    outref: { txId: 'rerate-order-b', ix: 1 },
    lovelaceIn: 9_000_000,
    minUsdmOut: 3_650_000,
    sundaeFeeLovelace: 2_000_000,
  },
];

test('re-rate builds one transaction from selected pending orders', async ({
  page,
}) => {
  const server = await serveDist();
  const buildRequests: unknown[] = [];
  const introspectRequests: unknown[] = [];

  try {
    await page.setViewportSize({ width: 1280, height: 900 });
    await mockPending(page);
    await page.route('**/v1/build/swap-rerate', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON();
      buildRequests.push(body);

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          srrCborHex: SINGLE_CBOR_HEX,
          srrDecision: 'single',
          srrReason: 'all selected orders fit in one transaction',
          srrReport: JSON.stringify({
            decision: 'single',
            selectedOrders: ['rerate-order-a#0', 'rerate-order-b#1'],
          }),
        }),
      });
    });
    await page.route('**/v1/tx/introspect', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON();
      introspectRequests.push(body);
      expect(body).toEqual({ cborHex: SINGLE_CBOR_HEX });

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          txid: SINGLE_TXID,
          requiredSigners: SINGLE_REQUIRED_SIGNERS,
          invalidHereafter: SINGLE_INVALID_HEREAFTER,
          scope: 'middleware',
        }),
      });
    });

    await openRerate(page, server.url, 'middleware');
    const orderRows = page.locator('label.repeated-row-card');
    await expect(orderRows).toHaveCount(2);
    await expect(orderRows.nth(0)).toContainText('5,100,000 base units');
    await expect(orderRows.nth(1)).toContainText('3,650,000 base units');
    await captureRerateScreenshot(page);

    await page.getByLabel('New rate (ADA/USDM)').fill('0.47');
    await selectOrder(page, 'rerate-order-a#0');
    await selectOrder(page, 'rerate-order-b#1');
    await page.getByLabel('collateral tx-in').fill(COLLATERAL_TX_IN);
    await page.getByLabel('wallet tx-in').fill(WALLET_TX_IN);

    const resultPanel = page.locator('#operate-result-panel');
    await expect(resultPanel).toContainText('built: single');
    await expect(resultPanel).toContainText('Decision: single');
    await expect(resultPanel).toContainText('Save to pending');

    expect(buildRequests).toEqual([
      {
        srrScope: 'middleware',
        srrSelectedOrders: ['rerate-order-a#0', 'rerate-order-b#1'],
        srrNewRate: 0.47,
        srrWalletTxIn: WALLET_TX_IN,
        srrCollateralTxIn: COLLATERAL_TX_IN,
      },
    ]);

    await page.getByRole('button', { name: 'Save to pending' }).click();
    await expect(resultPanel).toContainText(SINGLE_TXID);
    expect(introspectRequests).toEqual([{ cborHex: SINGLE_CBOR_HEX }]);
  } finally {
    await server.close();
  }
});

test('re-rate shows split decisions and reports', async ({ page }) => {
  const server = await serveDist();
  const buildRequests: unknown[] = [];

  try {
    await mockPending(page);
    await page.route('**/v1/build/swap-rerate', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON();
      buildRequests.push(body);

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          srrDecision: 'split',
          srrReason: SPLIT_REASON,
          srrReport: JSON.stringify({
            decision: 'split',
            reason: SPLIT_REASON,
            batches: 2,
          }),
        }),
      });
    });

    await openRerate(page, server.url, 'middleware');
    await page.getByLabel('New rate (ADA/USDM)').fill('0.51');
    await selectOrder(page, 'rerate-order-a#0');
    await page.getByLabel('wallet tx-in').fill(WALLET_TX_IN);

    const resultPanel = page.locator('#operate-result-panel');
    await expect(resultPanel).toContainText(`Decision: split`);
    await expect(resultPanel).toContainText(SPLIT_REASON);
    await resultPanel.getByRole('button', { name: 'Report' }).click();
    await expect(resultPanel).toContainText('batches');
    await expect(resultPanel).toContainText(SPLIT_REASON);
    await expect(
      resultPanel.getByRole('button', { name: 'Save to pending' }),
    ).toHaveCount(0);

    expect(buildRequests).toEqual([
      {
        srrScope: 'middleware',
        srrSelectedOrders: ['rerate-order-a#0'],
        srrNewRate: 0.51,
        srrWalletTxIn: WALLET_TX_IN,
        srrCollateralTxIn: null,
      },
    ]);
  } finally {
    await server.close();
  }
});

test('re-rate blocks empty pending-order scopes', async ({ page }) => {
  const server = await serveDist();
  const buildRequests: unknown[] = [];

  try {
    await mockPending(page);
    await page.route('**/v1/build/swap-rerate', async (route) => {
      buildRequests.push(route.request().postDataJSON());
      await route.fulfill({
        status: 500,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'empty scope should not build' }),
      });
    });

    await openRerate(page, server.url, 'network_compliance');
    await expect(
      page.getByText(/No pending swap orders for Network compliance/),
    ).toBeVisible();

    await page.getByLabel('New rate (ADA/USDM)').fill('0.49');
    await page.getByLabel('wallet tx-in').fill(WALLET_TX_IN);
    await expect(page.locator('#operate-result-panel')).toContainText('fix');
    await page.waitForTimeout(750);
    expect(buildRequests).toEqual([]);
  } finally {
    await server.close();
  }
});

async function openRerate(
  page: Page,
  baseUrl: string,
  scope: string,
): Promise<void> {
  await page.goto(`${baseUrl}/operate`);
  await page.getByRole('button', { name: 'Re-rate' }).click();
  await page.locator(`button[data-scope="${scope}"]`).click();
  await expect(page.getByRole('heading', { name: 'Pending orders' }))
    .toBeVisible();
}

async function selectOrder(page: Page, outref: string): Promise<void> {
  const index = ['rerate-order-a#0', 'rerate-order-b#1'].indexOf(outref);
  if (index < 0) {
    throw new Error(`unknown mocked order ${outref}`);
  }
  await page
    .locator('label.repeated-row-card')
    .nth(index)
    .locator('input[type="checkbox"]')
    .check();
}

async function mockPending(page: Page): Promise<void> {
  await page.route('**/v1/pending**', async (route) => {
    expect(route.request().method()).toBe('GET');
    const url = new URL(route.request().url());
    const scope = url.searchParams.get('scope') ?? 'core_development';

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(pendingResponse(scope)),
    });
  });
}

function pendingResponse(scope: string): PendingResponse {
  return {
    scope,
    entries: [
      { scope: 'core_development', orders: [] },
      { scope: 'middleware', orders: pendingOrders },
      { scope: 'network_compliance', orders: [] },
      { scope: 'ops_and_use_cases', orders: [] },
    ],
  };
}

async function captureRerateScreenshot(page: Page): Promise<void> {
  await mkdir(UI_REVIEW_ROOT, { recursive: true });
  await page.screenshot({
    path: path.join(UI_REVIEW_ROOT, '402-rerate-operate-desktop-1280.png'),
    fullPage: true,
  });
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
    res.end(JSON.stringify({ error: 'not mocked in rerate-mode test' }));
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

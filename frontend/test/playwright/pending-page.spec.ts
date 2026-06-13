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
const READY_WITNESSES = ['ready-witness-a-hex', 'ready-witness-b-hex'];
const EXPIRED_WITNESSES = [
  'expired-witness-a-hex',
  'expired-witness-b-hex',
];
const FAILURE_WITNESSES = [
  'failure-witness-a-hex',
  'failure-witness-b-hex',
];
const ATTACHED_CBOR_HEX = 'signed-ready-cbor-hex';
const SUBMITTED_TXID = 'submitted-ready-txid';
const REBUILT_CBOR_HEX = 'unsigned-rebuilt-cbor-hex';
const REBUILT_TXID = 'tx-rebuilt-001';
const REBUILT_REQUIRED_SIGNERS = ['rebuilt-signer-a', 'rebuilt-signer-b'];
const REBUILT_INVALID_HEREAFTER = 1_850;
const OPERATE_UNSIGNED_CBOR_HEX = 'unsigned-operate-cbor-hex';
const OPERATE_TXID = 'tx-operate-pending-001';
const OPERATE_REQUIRED_SIGNERS = [
  'operate-signer-a',
  'operate-signer-b',
];
const OPERATE_INVALID_HEREAFTER = 1_950;
const OPERATE_WALLET_ADDR =
  'addr1qoperatewallet000000000000000000000000000000000000000000000';
const REBUILD_BUILD_REQUEST = {
  network: 'mainnet',
  scope: 'core_development',
  swap: {
    from: {
      policy: '',
      asset: '',
      quantity: '2500000',
    },
    to: {
      policy: 'policy-rebuilt',
      asset: 'asset-rebuilt',
    },
    route: {
      pool: 'pool1opaque',
      minimumReceived: '42',
    },
  },
  metadata: {
    operator: 'slice-4',
    tags: ['pending', 'rebuild'],
  },
};

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

const submitEntries: PendingTxEntry[] = [
  {
    txid: 'tx-ready-submit-001',
    intent: { kind: 'swap' },
    unsignedTxHex: 'unsigned-ready-submit-hex',
    scope: 'core_development',
    requiredSigners: ['ready-signer-a', 'ready-signer-b'],
    invalidHereafter: '1500',
    witnesses: {
      'ready-signer-a': READY_WITNESSES[0],
      'ready-signer-b': READY_WITNESSES[1],
    },
    savedAt: '2026-06-13T11:00:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-missing-submit-001',
    intent: { kind: 'swap' },
    unsignedTxHex: 'unsigned-missing-submit-hex',
    scope: 'core_development',
    requiredSigners: ['missing-signer-a', 'missing-signer-b'],
    invalidHereafter: '1500',
    witnesses: { 'missing-signer-a': 'missing-witness-a-hex' },
    savedAt: '2026-06-13T11:05:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-expired-submit-001',
    intent: { kind: 'disburse' },
    unsignedTxHex: 'unsigned-expired-submit-hex',
    scope: 'middleware',
    requiredSigners: ['expired-signer-a', 'expired-signer-b'],
    invalidHereafter: '1100',
    witnesses: {
      'expired-signer-a': EXPIRED_WITNESSES[0],
      'expired-signer-b': EXPIRED_WITNESSES[1],
    },
    savedAt: '2026-06-13T11:10:00Z',
    supersedes: null,
  },
  {
    txid: 'tx-failure-submit-001',
    intent: { kind: 'reorganize' },
    unsignedTxHex: 'unsigned-failure-submit-hex',
    scope: 'ops_and_use_cases',
    requiredSigners: ['failure-signer-a', 'failure-signer-b'],
    invalidHereafter: '1500',
    witnesses: {
      'failure-signer-a': FAILURE_WITNESSES[0],
      'failure-signer-b': FAILURE_WITNESSES[1],
    },
    savedAt: '2026-06-13T11:15:00Z',
    supersedes: null,
  },
];

const rebuildableEntry: PendingTxEntry = {
  txid: 'tx-rebuild-original-001',
  intent: {
    kind: 'swap',
    buildEndpoint: '/v1/build/swap',
    buildRequest: REBUILD_BUILD_REQUEST,
  },
  unsignedTxHex: 'unsigned-rebuild-original-hex',
  scope: 'core_development',
  requiredSigners: ['old-signer-a', 'old-signer-b'],
  invalidHereafter: '1500',
  witnesses: {
    'old-signer-a': 'old-witness-a-hex',
    'old-signer-b': 'old-witness-b-hex',
  },
  savedAt: '2026-06-13T12:00:00Z',
  supersedes: null,
};

const missingRecipeEntry: PendingTxEntry = {
  txid: 'tx-rebuild-unavailable-001',
  intent: { kind: 'swap' },
  unsignedTxHex: 'unsigned-rebuild-unavailable-hex',
  scope: 'middleware',
  requiredSigners: ['legacy-signer-a'],
  invalidHereafter: '1500',
  witnesses: {},
  savedAt: '2026-06-13T12:05:00Z',
  supersedes: null,
};

test('operate saves built transactions to pending with zero witnesses', async ({
  page,
}) => {
  const server = await serveDist();
  const buildRequests: unknown[] = [];
  const introspectRequests: unknown[] = [];

  try {
    await page.route('**/v1/build/**', async (route) => {
      expect(route.request().method()).toBe('POST');
      const pathname = new URL(route.request().url()).pathname;
      expect(pathname).toBe('/v1/build/swap');
      const body = route.request().postDataJSON();
      buildRequests.push(body);

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ sbrCborHex: OPERATE_UNSIGNED_CBOR_HEX }),
      });
    });

    await page.route('**/v1/tx/introspect', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON();
      introspectRequests.push(body);
      expect(body).toEqual({ cborHex: OPERATE_UNSIGNED_CBOR_HEX });

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          txid: OPERATE_TXID,
          requiredSigners: OPERATE_REQUIRED_SIGNERS,
          invalidHereafter: OPERATE_INVALID_HEREAFTER,
          scope: 'core_development',
        }),
      });
    });

    await page.goto(`${server.url}/operate`);
    await page.getByRole('textbox', { name: 'wallet' }).fill(
      OPERATE_WALLET_ADDR,
    );
    await page
      .locator('#operate-signers-picker')
      .getByRole('button', { name: 'Middleware' })
      .click();
    await page.getByLabel('description').fill('operate pending proof');
    await page.getByLabel('justification').fill('handoff proof');

    await expect(page.locator('#operate-result-panel')).toContainText('built');

    const saveToPending = page.getByRole('button', {
      name: 'Save to pending',
    });
    await expect(saveToPending).toBeVisible({ timeout: 2_000 });
    await saveToPending.click();
    await expect(page.locator('#operate-result-panel')).toContainText(
      OPERATE_TXID,
    );

    await page.getByRole('link', { name: 'Pending co-signing' }).click();

    const activeLane = page.getByRole('region', {
      name: 'Active pending transactions',
    });
    await expect(activeLane).toContainText(OPERATE_TXID);
    for (const signer of OPERATE_REQUIRED_SIGNERS) {
      await expect(
        activeLane
          .locator('.signer-chip[data-active="false"]')
          .filter({ hasText: signer }),
      ).toContainText('Missing');
    }

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${OPERATE_TXID}`,
      })
      .click();

    const detail = page.getByRole('region', {
      name: 'Pending transaction detail',
    });
    for (const signer of OPERATE_REQUIRED_SIGNERS) {
      await expect(
        detail
          .locator('.pending-roster__row[data-active="false"]')
          .filter({ hasText: signer }),
      ).toContainText('Missing');
    }

    const stored = await getPendingEntry(page, OPERATE_TXID);
    expect(stored?.txid).toBe(OPERATE_TXID);
    expect(stored?.unsignedTxHex).toBe(OPERATE_UNSIGNED_CBOR_HEX);
    expect(stored?.requiredSigners).toEqual(OPERATE_REQUIRED_SIGNERS);
    expect(stored?.invalidHereafter).toBe(String(OPERATE_INVALID_HEREAFTER));
    expect(stored?.witnesses).toEqual({});
    expect(stored?.supersedes).toBeNull();
    expect(stored?.intent).toEqual({
      kind: 'swap',
      buildEndpoint: '/v1/build/swap',
      buildRequest: buildRequests[0],
    });
    expect(buildRequests).toHaveLength(1);
    expect(introspectRequests).toEqual([
      { cborHex: OPERATE_UNSIGNED_CBOR_HEX },
    ]);
  } finally {
    await server.close();
  }
});

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

test('pending page gates and submits complete active transactions', async ({
  page,
}) => {
  const server = await serveDist();
  const attachRequests: Record<string, unknown>[] = [];
  const submitRequests: Record<string, unknown>[] = [];
  const callOrder: string[] = [];
  const [
    readyEntry,
    missingEntry,
    expiredEntry,
    failureEntry,
  ] = submitEntries;

  try {
    await page.goto(`${server.url}/`);
    await seedPendingEntries(page, submitEntries);

    await page.route('**/v1/attach', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON() as Record<string, unknown>;
      attachRequests.push(body);

      if (body.unsignedTx === readyEntry.unsignedTxHex) {
        expect(body).toEqual({
          unsignedTx: readyEntry.unsignedTxHex,
          witnesses: READY_WITNESSES,
        });
        callOrder.push('attach:ready');
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ cborHex: ATTACHED_CBOR_HEX }),
        });
        return;
      }

      if (body.unsignedTx === failureEntry.unsignedTxHex) {
        expect(body).toEqual({
          unsignedTx: failureEntry.unsignedTxHex,
          witnesses: FAILURE_WITNESSES,
        });
        callOrder.push('attach:failure');
        await route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'attach refused by backend' }),
        });
        return;
      }

      throw new Error(`unexpected attach request ${JSON.stringify(body)}`);
    });

    await page.route('**/v1/submit', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON() as Record<string, unknown>;
      expect(body).toEqual({ cborHex: ATTACHED_CBOR_HEX });
      submitRequests.push(body);
      callOrder.push('submit');
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ txid: SUBMITTED_TXID }),
      });
    });

    await page.goto(`${server.url}/pending`);

    const activeLane = page.getByRole('region', {
      name: 'Active pending transactions',
    });
    const expiredLane = page.getByRole('region', {
      name: 'Expired pending transactions',
    });

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${missingEntry.txid}`,
      })
      .click();

    const detail = page.getByRole('region', {
      name: 'Pending transaction detail',
    });
    const submitButton = detail.getByRole('button', {
      name: 'Submit transaction',
    });

    await expect(submitButton).toBeDisabled();

    await expiredLane
      .getByRole('button', {
        name: `View pending transaction ${expiredEntry.txid}`,
      })
      .click();
    await expect(submitButton).toBeDisabled();

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${readyEntry.txid}`,
      })
      .click();
    await expect(submitButton).toBeEnabled();

    await submitButton.click();
    await expect(detail).toContainText(SUBMITTED_TXID);
    expect(attachRequests).toEqual([
      {
        unsignedTx: readyEntry.unsignedTxHex,
        witnesses: READY_WITNESSES,
      },
    ]);
    expect(submitRequests).toEqual([{ cborHex: ATTACHED_CBOR_HEX }]);
    expect(callOrder).toEqual(['attach:ready', 'submit']);

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${failureEntry.txid}`,
      })
      .click();
    const storedBeforeFailure = await getPendingEntry(
      page,
      failureEntry.txid,
    );

    await submitButton.click();
    await expect(detail).toContainText('Attach failed');

    const storedAfterFailure = await getPendingEntry(
      page,
      failureEntry.txid,
    );
    expect(storedAfterFailure?.witnesses).toEqual(
      storedBeforeFailure?.witnesses,
    );
    expect(callOrder).toEqual([
      'attach:ready',
      'submit',
      'attach:failure',
    ]);
  } finally {
    await server.close();
  }
});

test('pending page rebuilds stored recipes and supersedes history', async ({
  page,
}) => {
  const server = await serveDist();
  const buildRequests: unknown[] = [];
  const introspectRequests: unknown[] = [];

  try {
    await page.goto(`${server.url}/`);
    await seedPendingEntries(page, [rebuildableEntry, missingRecipeEntry]);

    await page.route('**/v1/build/**', async (route) => {
      expect(route.request().method()).toBe('POST');
      const pathname = new URL(route.request().url()).pathname;
      if (pathname !== '/v1/build/swap') {
        throw new Error(`unexpected build endpoint ${pathname}`);
      }

      const body = route.request().postDataJSON();
      buildRequests.push(body);
      expect(body).toEqual(REBUILD_BUILD_REQUEST);

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ sbrCborHex: REBUILT_CBOR_HEX }),
      });
    });

    await page.route('**/v1/tx/introspect', async (route) => {
      expect(route.request().method()).toBe('POST');
      const body = route.request().postDataJSON();
      introspectRequests.push(body);
      expect(body).toEqual({ cborHex: REBUILT_CBOR_HEX });

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          txid: REBUILT_TXID,
          requiredSigners: REBUILT_REQUIRED_SIGNERS,
          invalidHereafter: REBUILT_INVALID_HEREAFTER,
          scope: 'core_development',
        }),
      });
    });

    await page.goto(`${server.url}/pending`);

    const activeLane = page.getByRole('region', {
      name: 'Active pending transactions',
    });
    const historyLane = page.getByRole('region', {
      name: 'Pending transaction history',
    });

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${rebuildableEntry.txid}`,
      })
      .click();

    const detail = page.getByRole('region', {
      name: 'Pending transaction detail',
    });
    const rebuildButton = detail.getByRole('button', {
      name: 'Rebuild transaction',
    });
    await expect(rebuildButton).toBeEnabled();
    await rebuildButton.click();

    await expect(detail).toContainText(REBUILT_TXID);

    const rebuilt = await getPendingEntry(page, REBUILT_TXID);
    expect(rebuilt?.txid).toBe(REBUILT_TXID);
    expect(rebuilt?.unsignedTxHex).toBe(REBUILT_CBOR_HEX);
    expect(rebuilt?.requiredSigners).toEqual(REBUILT_REQUIRED_SIGNERS);
    expect(rebuilt?.invalidHereafter).toBe(
      String(REBUILT_INVALID_HEREAFTER),
    );
    expect(rebuilt?.witnesses).toEqual({});
    expect(rebuilt?.supersedes).toBe(rebuildableEntry.txid);

    const original = await getPendingEntry(page, rebuildableEntry.txid);
    expect(original?.witnesses).toEqual(rebuildableEntry.witnesses);

    await expect(activeLane).toContainText(REBUILT_TXID);
    await expect(activeLane).toContainText(
      `supersedes ${rebuildableEntry.txid}`,
    );
    await expect(historyLane).toContainText(rebuildableEntry.txid);
    await expect(historyLane).toContainText(`superseded by ${REBUILT_TXID}`);

    await activeLane
      .getByRole('button', {
        name: `View pending transaction ${missingRecipeEntry.txid}`,
      })
      .click();
    await expect(detail).toContainText('rebuild unavailable');

    expect(buildRequests).toEqual([REBUILD_BUILD_REQUEST]);
    expect(introspectRequests).toEqual([{ cborHex: REBUILT_CBOR_HEX }]);
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

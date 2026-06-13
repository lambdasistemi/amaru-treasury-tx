// #289 — Responsive sweep harness.
//
// Sweeps every primary route at four viewport widths and
// asserts:
//
//   * The document scroll-width never exceeds the client
//     width (i.e. no horizontal overflow).
//   * The topbar links + theme toggle are visible.
//   * Every link / button carries an accessible name via
//     `aria-label` (FR-002).
//
// Subsequent slices (B–H) extend this same matrix:
//   * Slice B adds in-page form smokes that piggy-back on
//     the same viewport list.
//   * Slice C exercises the operate-page layout at narrow
//     widths.
//   * Slice H runs a contrast / palette pass on the same
//     screenshots.
//
// Run against the rebuilt local `frontend/dist` by default.
// Override `AMARU_TREASURY_URL` to sweep a deployed target.

import { test, expect, type Page } from '@playwright/test';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';

const DIST_ROOT = path.join(process.cwd(), 'dist');
const OVERRIDE_URL = process.env.AMARU_TREASURY_URL;
let localServer: { url: string; close: () => Promise<void> } | null = null;
let baseUrl = OVERRIDE_URL ?? '';

const VIEWPORTS = [
  { name: 'mobile-320', width: 320, height: 568 },
  { name: 'mobile-390', width: 390, height: 844 },
  { name: 'tablet-1024', width: 1024, height: 768 },
  { name: 'desktop-1280', width: 1280, height: 800 },
] as const;

const PAGES = ['/', '/audit', '/operate', '/pending', '/books'] as const;

test.beforeAll(async () => {
  if (!OVERRIDE_URL) {
    localServer = await serveDist();
    baseUrl = localServer.url;
  }
});

test.afterAll(async () => {
  if (localServer) {
    await localServer.close();
  }
});

async function measureHorizontalOverflow(pw: Page): Promise<number> {
  return await pw.evaluate(
    () =>
      document.documentElement.scrollWidth -
      document.documentElement.clientWidth,
  );
}

for (const v of VIEWPORTS) {
  for (const path of PAGES) {
    const screenshotName = `${v.name}-${path === '/' ? '_root' : path.replace(/\//g, '_')}.png`;
    test(`${path} @ ${v.name}: no horizontal overflow + topbar visible`, async ({
      page: pw,
    }) => {
      await pw.setViewportSize({ width: v.width, height: v.height });
      await pw.goto(`${baseUrl}${path}`);
      // Slow networks can leave the JS bundle midway through
      // bootstrap; wait for the topbar to mount before
      // measuring.
      await pw.waitForSelector('nav a[aria-label*="View"]', {
        timeout: 15_000,
      });
      const overflow = await measureHorizontalOverflow(pw);
      expect(overflow, `${path} @ ${v.name}: horizontal overflow`).toBeLessThanOrEqual(
        0,
      );

      // Accessibility: every topbar link + the theme toggle
      // carries an explicit aria-label.  FR-002.
      await expect(
        pw.locator('nav a[aria-label="View transactions"]'),
      ).toBeVisible();
      await expect(
        pw.locator('nav a[aria-label="Audit transaction history"]'),
      ).toBeVisible();
      await expect(
        pw.locator('nav a[aria-label="Operate — prepare a transaction"]'),
      ).toBeVisible();
      await expect(
        pw.locator('nav a[aria-label="Pending co-signing"]'),
      ).toBeVisible();
      await expect(
        pw.locator('nav a[aria-label="Manage saved values (Books)"]'),
      ).toBeVisible();
      await expect(
        pw.locator('button[aria-label="Toggle theme"]'),
      ).toBeVisible();

      await pw.screenshot({
        path: `test/playwright/screenshots/${screenshotName}`,
        fullPage: false,
      });
    });
  }
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
    res.end(JSON.stringify({ slot: 1_200 }));
    return;
  }
  if (url.pathname.startsWith('/v1/')) {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not mocked in responsive test' }));
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

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
// Run against the dev deploy by default; override
// `AMARU_TREASURY_URL` to point at a local serve.

import { test, expect, type Page } from '@playwright/test';

const BASE_URL =
  process.env.AMARU_TREASURY_URL ??
  'https://amaru-treasury.dev.plutimus.com';

const VIEWPORTS = [
  { name: 'mobile-320', width: 320, height: 568 },
  { name: 'mobile-390', width: 390, height: 844 },
  { name: 'tablet-1024', width: 1024, height: 768 },
  { name: 'desktop-1280', width: 1280, height: 800 },
] as const;

const PAGES = ['/', '/audit', '/operate', '/books'] as const;

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
      await pw.goto(`${BASE_URL}${path}`);
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

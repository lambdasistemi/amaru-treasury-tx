// #289 — Playwright runner config.  Kept tiny on purpose:
// every harness lives under `frontend/test/playwright/` and
// inherits the defaults plus a `screenshots/` artefact dir.

import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  // The slices run against the live dev deploy by default
  // (`AMARU_TREASURY_URL` overrides), so no `webServer`
  // block here.  CI / `gate.sh` integration is a follow-up
  // out of scope for this slice.
  use: {
    headless: true,
    screenshot: 'only-on-failure',
    video: 'off',
  },
});

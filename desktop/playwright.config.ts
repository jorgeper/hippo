// The browser test (npm run e2e). global-setup writes a sample folder, builds the page and starts the desk server on a free
// port; the tests read its URL from HIPPO_E2E_URL. `npm test` (node --test) does not look in e2e/.
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: 'e2e',
  globalSetup: './e2e/global-setup.ts',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  reporter: [['list']],
  outputDir: 'test-results',
  use: {
    viewport: { width: 1440, height: 900 },
    // Headless Chromium has no GPU: software WebGL for the three.js page.
    launchOptions: { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] },
  },
});

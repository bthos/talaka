// Visual regression suite (screenshots-testing skill).
// Run it in the container (in-container.sh) so every machine renders the same
// pixels; baselines in tests/visual/__screenshots__/ are committed to git.
import { defineConfig, devices } from '@playwright/test';

const PORT = Number(process.env.VISUAL_PORT ?? 6007);
// Storybook build to shoot. For app pages, point webServer at the app's
// preview server instead and set VISUAL_BASE_URL if it runs elsewhere.
const STATIC_DIR = process.env.VISUAL_STORYBOOK_DIR ?? 'storybook-static';

export default defineConfig({
  testDir: './tests/visual',
  // No {platform} in the path: the container is the one reference renderer.
  snapshotPathTemplate: '{testDir}/__screenshots__/{projectName}/{arg}{ext}',
  outputDir: 'test-results/visual',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  // Never retry: a retry that passes hides a flaky shot.
  retries: 0,
  // A new story's first shot is a baseline only once the user accepts it;
  // --update-snapshots on the command line still overrides this.
  updateSnapshots: 'none',
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'visual-report' }]],
  expect: {
    toHaveScreenshot: {
      animations: 'disabled',
      caret: 'hide',
      scale: 'css',
      // Per-pixel colour distance (0..1) that still counts as equal; absorbs
      // anti-aliasing only. Do not raise it or add maxDiffPixels to get green.
      threshold: 0.2,
    },
  },
  use: {
    baseURL: process.env.VISUAL_BASE_URL ?? `http://127.0.0.1:${PORT}`,
    reducedMotion: 'reduce',
    locale: 'en-US',
    timezoneId: 'UTC',
    colorScheme: 'light',
  },
  webServer: process.env.VISUAL_BASE_URL
    ? undefined
    : {
        command: `npx --yes http-server ${STATIC_DIR} -p ${PORT} -s`,
        url: `http://127.0.0.1:${PORT}`,
        reuseExistingServer: !process.env.CI,
      },
  // Modes. Keep only what the product has; each one multiplies the shots.
  // metadata.globals is passed to Storybook as &globals=… (toolbar globals).
  projects: [
    // Desktop layout breakpoint.
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 800 } } },
    // Mobile layout breakpoint.
    { name: 'mobile', use: { ...devices['Pixel 7'] } },
    // Dark theme — delete if the app has none; rename the global to the one .storybook/preview sets.
    {
      name: 'desktop-dark',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 800 }, colorScheme: 'dark' },
      metadata: { globals: 'theme:dark' },
    },
  ],
});

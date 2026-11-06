// Renders contact-sheet HTML files to PNG beside them (<name>.sheet.html →
// <name>.sheet.png). Called by contact-sheet.sh, normally inside the Playwright
// container via in-container.sh --node. Review aid only: these PNGs are never
// compared or committed.
// Usage: node render-sheets.mjs SHEET.html [SHEET.html …]   (paths from cwd)
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// Resolve Playwright from the project (cwd), not from this script's folder.
const require = createRequire(path.join(process.cwd(), 'package.json'));
let chromium;
try {
  ({ chromium } = require('@playwright/test'));
} catch {
  ({ chromium } = require('playwright'));
}

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error('usage: node render-sheets.mjs SHEET.html [SHEET.html …]');
  process.exit(2);
}

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1400, height: 800 } });
  for (const f of files) {
    const abs = path.resolve(f);
    await page.goto(pathToFileURL(abs).href);
    await page.evaluate(() => Promise.all(
      Array.from(document.images)
        .filter((img) => !img.complete)
        .map((img) => new Promise((r) => { img.onload = img.onerror = r; })),
    ));
    await page.screenshot({ path: abs.replace(/\.html$/, '.png'), fullPage: true });
  }
} finally {
  await browser.close();
}

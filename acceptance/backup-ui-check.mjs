/* global document, console */
import { chromium } from '@playwright/test';
const base = 'http://127.0.0.1:5599/acceptance/backup-ui-harness.html';
const shots = [
  ['?case=ok', 1366, 900, 'acceptance/backup-ui-1366.png'],
  ['?case=ok', 390, 844, 'acceptance/backup-ui-390.png'],
  ['?case=failed', 1366, 900, 'acceptance/backup-ui-failed-1366.png'],
  ['?case=empty', 1366, 900, 'acceptance/backup-ui-empty-1366.png'],
];
const browser = await chromium.launch();
for (const [q, w, h, out] of shots) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  await page.goto(base + q, { waitUntil: 'networkidle' });
  await page.getByRole('heading', { name: 'النسخ الاحتياطي', exact: true }).waitFor();
  if (q.includes('empty')) {
    if (!(await page.getByTestId('backup-none').isVisible())) throw new Error('empty state missing');
  } else if (!(await page.getByTestId('backup-last-success-at').isVisible())) throw new Error('last success missing');
  if (q.includes('failed') && !(await page.getByText('آخر محاولة نسخ فشلت', { exact: true }).isVisible())) throw new Error('failure warning missing');
  await page.getByRole('button', { name: 'تحديث', exact: true }).click();
  await page.waitForTimeout(200);
  await page.screenshot({ path: out, fullPage: true });
  // no horizontal scroll check
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  if (overflow !== 0) throw new Error('horizontal overflow');
  console.log('PASS', out, 'horizontal-overflow-px:', overflow);
  await page.close();
}
await browser.close();

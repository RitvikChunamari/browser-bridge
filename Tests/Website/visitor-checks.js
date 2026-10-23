// Browser-level acceptance seam. Run this function with a Playwright Page and
// Browser Bridge served at BASE_URL (default local port 8893). No personal data.
async (page) => {
  const base = 'http://127.0.0.1:8893/';
  const checks = [];
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  function check(condition, name) {
    if (!condition) throw new Error(name);
    checks.push(name);
  }
  await page.goto(base + '?from=safari&to=chrome&family=safari');
  check(await page.locator('#source').inputValue() === 'safari', 'Shared route restores source');
  check(await page.locator('tbody tr').count() === 1, 'Shared filter restores ledger');
  check((await page.locator('#route-summary').innerText()).includes('bookmark HTML'), 'Safari boundary visible');
  await page.locator('#destination').selectOption('safari');
  check(await page.locator('#simulate').isDisabled(), 'Same-browser simulation blocked');
  await page.locator('#destination').selectOption('dia');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.locator('#simulate').focus();
  await page.keyboard.press('Enter');
  await page.getByText('Your next chapter.', { exact: true }).waitFor();
  check((await page.locator('#demo-result').innerText()).includes('guided import'), 'Keyboard simulation reports manual boundary');
  await page.locator('#source').selectOption('chrome');
  await page.locator('#destination').selectOption('brave');
  check((await page.locator('#route-summary').innerText()).includes('Chrome 156.0.8078.48 → Brave 156.1.98.60'), 'Verified route exposes exact browser versions');
  await page.locator('#source').selectOption('brave');
  await page.locator('#destination').selectOption('chrome');
  check((await page.locator('#route-summary').innerText()).startsWith('Guided route'), 'Reverse route remains guided');
  await page.locator('#family').selectOption('all');
  check(await page.locator('tbody tr').count() === 11, 'All eleven browsers visible');
  check(new URL(page.url()).searchParams.get('family') === 'all', 'Shareable filter state updates');
  await page.goto(base);
  await page.keyboard.press('Tab');
  check(await page.locator('.skip').evaluate(element => element === document.activeElement), 'Skip link first in keyboard order');
  await page.keyboard.press('Enter');
  check(await page.evaluate(() => location.hash) === '#main', 'Skip link reaches main');
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `No page overflow at ${width}`);
  }
  check(errors.length === 0, 'No runtime errors');
  return { checks, errors };
}

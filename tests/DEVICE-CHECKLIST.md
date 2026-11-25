# قائمة التحقق اليدوية على الأجهزة (البند 7.6)

Automated Firefox and WebKit projects (`firefox`, `webkit` in `playwright.config.ts`) test the engines on a build machine. They are not Safari on an iPhone and not Chrome on an Android phone. Only this list, filled in by a person on a physical device, counts as device evidence.

## Status

| Device | OS and browser version | Date | Tester | Evidence (photo or screen recording path) | Result |
|---|---|---|---|---|---|
| iPhone (model: ___) | iOS ___ / Safari | not executed | | | not executed |
| Android phone (model: ___) | Android ___ / Chrome | not executed | | | not executed |

Nothing in this file is executed yet. Change a row only with a real date, tester and evidence file. Do not fill a row from an emulator.

## Steps on each device (one pass is about 20 minutes, note the time of each step)

1. Open the guest page. Check Arabic right-to-left text, fonts and no horizontal scroll.
2. Guest lookup: phone, then booking number, then the booking status page.
3. Sign in as supervisor. Check the bottom bar, «المزيد» drawer, and that Escape or a tap outside closes it.
4. Reservations list: filter, open one reservation, check the next-step button.
5. New reservation: type a name, reload, restore the draft.
6. «الرموز»: open a unit that must change, enter a new code, tick the field test, save. Check the unit turns green.
7. Export menu: open «تصدير Excel» and «طباعة / PDF», choose the page scope, check the file or print preview opens.
8. Keyboard on screen: check the field being typed stays visible and the save button is reachable.
9. Rotate to landscape and back on one list page.
10. Turn off the network, check the offline line shows, turn it on, check the page recovers.

## What each failure note must hold

Device and OS version, the step number, what was seen, a photo, and whether it repeats.

## Automated coverage (for contrast)

`tests/e2e/cross_browser.spec.ts` the six flows on `firefox`, `webkit` (desktop Safari profile) only. Run `npx playwright install firefox webkit` first. Execution evidence is recorded separately in the release test log. This checklist never counts automated engine results as physical-device evidence.

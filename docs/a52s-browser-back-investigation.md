# A52s internal browser back investigation (2026-10-04)

Status: reproduced and fixed; user reports no recurrence so far. Preparing
v1.0.21+28 release at the user's request without a currently connected phone.

## Reproduction and fix

At 07:04:58–07:05:11 the user reproduced the failure with OHO+ on the
TongHanja page. Each attempt logs an accepted DOWN, another DOWN 1–2 ms
later, then an UP suppressed with matchingDown=false. No onBackPressed
follows. MainActivity's duplicate DOWN branch clears the accepted DOWN.

The installed Flutter SDK's KeyboardManager.java explicitly redispatches
the original unhandled KeyEvent through the Activity. MainActivity previously
treated this framework round-trip as another gesture. Added a weak event
registry: an already-forwarded event passes to super without changing the
debounce state; distinct events retain the existing duplicate protection.
Both DOWN and UP need this treatment. JVM regression checks cover identity,
distinct duplicates, one-use reservations, and asynchronous ordering.

Device verification remains required to confirm redispatch passthrough logs,
successful OHO+ return on both sites, and absence of extra route pops.

## Installed candidate observations

- Release-mode candidate built successfully (assembleRelease exit 0, 110.8 s)
  and installed on A52s with `install -r` returning Success. Version remains
  1.0.20+27 for this local test; it is not the published v1.0.20 APK.
- JVM regression runner reports 8 assertions passed.
- New process 27866 logs at 07:12:03.314/.319 show redispatch passthrough
  for DOWN and UP, followed by onBackPressed at .321. The same successful
  native sequence repeats at 07:12:04, :05, :07, :24, :25, and :26.
  This confirms the framework redispatch diagnosis and the native-path fix.
- A subsequent screenshot still shows TongHanja; it cannot establish whether
  the user reopened it or browser history kept the same page. Do not infer
  end-to-end success from native logs. User confirmation for both sites is
  pending, and Flutter/browser-history diagnostics may still be needed.
- At 07:14–07:15, controlled ADB comparisons opened each site from the kanji
  sheet, scrolled the WebView to give it input focus, then sent one BACK.
  Screenshots verified both TongHanja and Nihongo Kanji returned to the kanji
  detail sheet, with the study screen still underneath (no extra route pop).
  This proves system BACK screen behavior for these cases, not final OHO+
  acceptance. The user has been asked to report the two OHO+ outcomes.

## Evidence

- Connected device: R5CR82GV7X / SM_A528N.
- Existing logcat at 06:59:47.306 shows KEYCODE_BACK DOWN accepted;
  UP arrives at .308 and Activity.onBackPressed at .311.
  This proves native dispatch for that event, not that the browser handled it
  or that this was the user's failed gesture.
- MainActivity suppresses new DOWN events within 700 ms, duplicate UP events
  within 80 ms, and any UP more than 250 ms after its accepted DOWN.
  Therefore a slow DOWN/UP pair can be discarded even without a duplicate.
  Repeated DOWN events can also clear the accepted-down state. Whether OHO+
  produces either pattern during the reported failure remains unverified.
- InAppBrowserPage additionally uses the shared 420 ms NavigationBackGate.
  It then awaits WebView.canGoBack and either goes back in WebView history or
  pops the Flutter route. No timeout or exception handling surrounds this path.
- Browser history URL changes and back-operation completion are not currently
  recorded. Existing Flutter navigation events are stored in the app-private
  diagnostic journal, not logcat.
- `run-as com.vocaflow.app` is rejected because the installed APK is not
  debuggable. Do not clear app data or replace it with a differently signed app.
- The current screen is covered by the user's lock-screen app; requested that
  the user unlock and open the affected browser page for observation.

## Next verification

1. Observe a failed OHO+ gesture and correlate native input with the app's
   exported navigation journal (key / gate / browser back state / route pop).
2. Distinguish native suppression, Flutter gate suppression, WebView operation
   failure, and a history entry that returns to visually identical content.
3. Reproduce the responsible path before selecting the fix. Cover ordinary
   back, repeated real gestures, duplicate events, browser history, and return
   to the underlying kanji detail sheet without popping the study route.
4. Verify both requested sites on A52s using the user's OHO+ gesture. Synthetic
   ADB BACK alone is insufficient evidence of an OHO+ fix.

No Firestore card data has been edited.

## User follow-up and release validation

The user reported that the issue has not recurred and will report any later
recurrence. This is limited real-use confirmation, not proof that every
intermittent navigation issue is eliminated. User subsequently requested a
GitHub release without device installation. Flutter suite: 142 tests passed;
native redispatch regression runner: 8 assertions passed. Release also adds
an optional undo haptic setting that defaults to off.

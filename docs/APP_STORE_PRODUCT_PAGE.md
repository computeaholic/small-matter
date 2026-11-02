# Small Matter — App Store product-page copy

**Product:** Small Matter · **App Store ID:** 6819082403 · **Platform:** macOS
**Last editorial update:** November 2, 2026

This document is a versioned **marketing source of truth**, not evidence that every field is live in App Store Connect. Check the authenticated Apple record before claiming publication. Preserve pricing, territories, privacy, and manual-release settings unless separately authorized.

## Positioning

**Promise:** See what your Mac is doing. Understand what changed. Keep your data yours.

**Audience:** Mac owners and developers who want clear system performance, meaningful changes, and local evidence—without an account or analytics.

**Differentiation:** Performance at a glance; trustworthy, evidence-backed changes; a privacy-first local experience; explicit limits rather than pretend sensor readings.

## Subtitle (29 characters) — corrected for Apple Guideline 5.2.5

Performance without guesswork

## Promotional text (159 characters)

See what your Mac is doing—and what changed. Live CPU, memory, and network activity, observed system changes, and evidence you control. No account or tracking.

## Description

Your Mac does a lot behind the scenes. Small Matter makes it easier to see what's happening now—and understand what actually changed.

Get a clean, live look at CPU, memory, and network activity, alongside battery, storage, and thermal status. When something catches your attention, go beyond a snapshot: review observed changes, capture a moment worth investigating, and export evidence you can keep or share.

SEE YOUR MAC AT A GLANCE
- CPU usage and short-term trends
- Memory use, pressure, compression, cache, and swap
- Network download and upload activity
- Battery charge, health, cycles, and power state
- Storage capacity and available space
- macOS thermal state and supported cooling readings

UNDERSTAND WHAT CHANGED
- Review observed storage, network, and power transitions
- Capture a bounded before-and-after window around a moment you want to investigate
- See where evidence is incomplete instead of mistaking missing data for certainty
- Export your evidence in readable text or structured JSON

PRIVATE BY DESIGN
- No account required
- No advertising, analytics, tracking, or cloud telemetry
- Your observations stay on your Mac unless you choose to export them
- Read-only hardware monitoring: macOS remains in charge of fans, charging, and thermal policy

Small Matter is deliberately honest about its limits. Some hardware sensor readings are unavailable on certain Macs or in the App Sandbox. When the system cannot provide a reliable value, you'll see that it's unavailable—not a guess.

Less noise. More context. A clearer understanding of your Mac.

## Search keywords (96 ASCII bytes)

cpu monitor,memory usage,network activity,battery health,thermal,performance,diagnostics,storage

## What's New — for version 1.1.0 (12), where appropriate

A clearer look at your Mac.

- A redesigned, performance-first Overview puts CPU, memory, and network activity front and center.
- More useful context around observed system changes and captured incidents.
- Improved local evidence-storage recovery to help capture keep working within its bounded storage limit.
- Refinements to evidence exports, responsive layouts, and accessibility.

Small Matter stays local-first, read-only, and transparent about unavailable hardware readings.

## Screenshot plan — use real shipping-app captures only

1. **Your Mac, at a glance** — authentic wide performance-first Overview with CPU, Memory, and Network together.
2. **Live activity. Clear trends.** — authentic Performance page with CPU, memory, and network graphs.
3. **See what actually changed** — authentic Recent Changes with supported observations and accurate evidence coverage.
4. **Capture the moment. Keep the evidence.** — authentic Capture / export flow with personal identifiers and private paths omitted.

Respect Apple's required dimensions. Do not invent, composite, or fabricate readings, sensors, incidents, or application states. Recheck every screenshot against the actual distribution build.

## App Review rejection and metadata correction (November 2, 2026)

- **Submission:** `1a8dd09e-26cb-4400-a83e-63aebbfc2ac2`; reviewed build `1.1.0 (12)` on MacBook Air (15-inch, M3, 2024).
- **Guideline:** Apple cited **5.2.5**, explicitly identifying use of **Mac in the app subtitle** as inappropriate. The earlier proposed subtitle was `See what your Mac is doing`.
- **Remedy:** Replace the App Store Connect subtitle with **Performance without guesswork** (29 characters); no Apple product name in the subtitle. Keep the app name, bundle identity, binary, review screenshots, and release configuration unchanged unless Apple requires a separate correction.
- **Follow-up:** Save the new subtitle in authenticated App Store Connect and reply to the original App Review message requesting review of the existing 1.1.0 (12) binary. Use `Resolve` / `Edit` / `Resubmit` only if the live Apple submission workflow requires it; do not cancel, upload again, or create Build 13 for a subtitle-only issue.
- **Prevent recurrence:** The above suggested keyword list also deliberately omits Apple product trademarks. Product-compatibility references in long descriptions are subject to Apple’s trademark-use rules; avoid using Apple marks as attention-grabbing names, slogans, subtitles, or keyword stuffing.
- **Status:** This Git documentation change is **not** proof that the App Store Connect subtitle has been edited or that Apple resumed review. Record the actual field value and review status after applying the fix.

Apple sources: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [Apple trademark guidelines](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html), [App and submission statuses](https://developer.apple.com/help/app-store-connect/reference/app-information/app-and-submission-statuses).

## Claim boundaries and publication steps

- **Cleanup:** Do not advertise broad user-scoped Cleanup with quarantine/undo as a Mac App Store capability. The App Store build supports conservative qualified app-owned disposable-data handling; permanent deletion of arbitrary selected data and Xcode Derived Data deletion are disabled pending additional qualification.
- **Hardware:** Do not imply fan control, charging control, full AppleSMC sensor access, or complete coverage on every Mac.
- **Evidence:** Capture is bounded and may complete with limitations. Missing evidence does not prove that nothing happened. Retention is bounded, not unlimited.
- **Privacy:** The app has no account, advertising, analytics, tracking, or cloud telemetry; user-directed export is separate.
- **Editing:** Promotional text may be independently editable in App Store Connect; subtitle, description, keywords, and screenshots can require an editable app version. Verify Apple's live workflow rather than changing an approved or released version merely to update copy.
- **Release:** No source-only documentation commit changes an uploaded binary, an App Review result, or a public App Store listing. Use authenticated App Store Connect to apply and verify metadata.
- **Readiness:** This is editorial copy to apply at the next Apple-supported opportunity; record exact saved field values and Apple status before marking it published.

Public product page: https://apps.apple.com/us/app/small-matter/id6819082403

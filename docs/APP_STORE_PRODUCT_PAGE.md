# Small Matter — App Store product-page copy and screenshot handoff

**Product:** Small Matter
**App Store ID:** 6819082403
**Platform:** macOS
**Target binary:** 1.1.0 (12)
**Last editorial update:** November 2, 2026

This file is the repository source of truth for App Store metadata and screenshot assembly prep. It does **not** change App Store Connect state by itself.

## Hard publishing gate (do not disturb active review)

Build `1.1.0 (12)` was resubmitted after subtitle correction. While a version is `Waiting for Review` or `In Review`, Apple blocks screenshot and preview edits for that version. Do not cancel or withdraw this submission only to adjust merchandising text or images.

Apple status reference: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-and-submission-statuses>

## Copy/paste fields for App Store Connect (production-ready)

Use this block exactly when App Store Connect allows editing for the intended version.

### Product name (unchanged)

`Small Matter`

### Subtitle (fixed per Guideline 5.2.5; 29/30 chars)

`Performance without guesswork`

### Promotional text (168/170 chars)

`See live CPU, memory, and network activity, understand meaningful system changes, and keep local evidence you can export—without accounts, tracking, or cloud telemetry.`

### Keywords (96/100 bytes, ASCII)

`cpu monitor,memory usage,network activity,battery health,thermal,performance,diagnostics,storage`

### Full description

Small Matter helps you understand your Mac without guesswork.

See live CPU, memory, and network activity in a performance-first overview, then drill into details when something looks off. Follow storage, power, and network transitions in Recent Changes, capture a bounded incident window, and export your own evidence in readable text or structured JSON.

PRIVATE BY DESIGN
- No account required
- No advertising, analytics, tracking, or cloud telemetry
- Observations stay on your Mac unless you choose to export

HONEST ABOUT LIMITS
- Read-only hardware monitoring; macOS remains in control of fans, charging, and thermal policy
- Some readings are unavailable on certain Macs or in the App Sandbox
- When a reliable value is unavailable, Small Matter labels it as unavailable instead of guessing

APP STORE CLEANUP SCOPE
- The Mac App Store build limits Cleanup to qualified Small Matter-owned disposable data
- It does not claim broad quarantine/undo workflows, arbitrary selected-folder permanent deletion, or Xcode Derived Data cleanup

Less noise. More context. A clearer understanding of your Mac.

### What's New in 1.1.0

A clearer look at your Mac.

- Redesigned performance-first Overview puts CPU, memory, and network front and center.
- Expanded context in Recent Changes and incident evidence summaries.
- Improved local evidence-storage recovery so bounded capture remains reliable.
- Refinements to evidence export, responsive layouts, and accessibility.

Small Matter remains local-first, read-only, and explicit about unavailable sensor states.

## Screenshot storyboard (Mac App Store)

Preferred upload size: **2560×1600 PNG** where accepted by Apple upload validation. Alternate accepted sizes are validated by script output against Apple's current screenshot specification.

1. **Your Mac, at a glance** — performance-first Overview (CPU, memory, network hero cards).
2. **Live activity, clear trends** — Performance details with CPU/memory/network charts.
3. **See what changed** — Recent Changes with supported observations and visible evidence boundaries.
4. **Capture the moment** — bounded incident capture state.
5. **Keep your evidence** — text/JSON export view with no personal identifiers.
6. *(Optional)* **Dark mode overview** — authentic dark appearance capture if available.

Rules:
- Use only authentic application screenshots from the shipping app build.
- Do not fabricate readings, unsupported sensors, fan control, charging control, or cleanup breadth.
- Do not include private user paths, serial numbers, tokens, or unredacted personal evidence.

## Reproducible screenshot production path (macOS only)

The cloud runner cannot capture owner GUI/TestFlight screens. Screenshot creation is therefore marked pending in-repo until local macOS capture is run.

### 1) Generate pending packet (current repository state)

```bash
/home/runner/work/small-matter/small-matter/scripts/prepare_app_store_screenshots.sh \
  --pending \
  --output-root /home/runner/work/small-matter/small-matter/docs/app_store_assets/runs
```

### 2) Generate validated packet on local macOS capture host

Capture authentic PNGs into a local folder using these exact filenames:

- `01-overview-performance.png`
- `02-performance-details.png`
- `03-recent-changes.png`
- `04-incident-capture-export.png`
- `05-battery-thermal.png`
- optional `06-dark-mode-overview.png`

Then run:

```bash
/home/runner/work/small-matter/small-matter/scripts/prepare_app_store_screenshots.sh \
  --source-dir /ABSOLUTE/PATH/TO/CAPTURES \
  --origin "small-matter-1.1.0(12)-local-capture" \
  --version 1.1.0 \
  --build 12 \
  --output-root /home/runner/work/small-matter/small-matter/docs/app_store_assets/runs
```

Script guarantees:
- macOS-only validation (`sips`) and PNG MIME checks
- accepted-dimension checks (`1280x800`, `1440x900`, `2560x1600`, `2880x1800`)
- no upscaling step (copy-only), deterministic slot ordering, and dimension consistency
- per-run folder creation without overwriting prior runs
- SHA-256 manifest (`manifest.json`) plus manual review checklist

Current repository marker: `/home/runner/work/small-matter/small-matter/docs/app_store_assets/SCREENSHOT_CAPTURE_PENDING`

## Claim boundaries and compliance notes

- Keep subtitle exactly `Performance without guesswork` unless legal review approves a replacement.
- Do not use Apple trademarks in subtitle/keywords for attention-grabbing placement.
- Do not claim broad Cleanup/quarantine/undo functionality in Mac App Store metadata.
- Do not state or imply fan control, charging control, or universal sensor coverage.
- Promotional text may be editable independently; description/keywords/screenshots may require an editable version depending on Apple workflow.
- Repository edits do not publish metadata or screenshots; App Store Connect actions remain manual.

Public listing: <https://apps.apple.com/us/app/small-matter/id6819082403>

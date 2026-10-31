# Experience 2.0 integration decisions

This record describes the canonical `small-matter` integration from `origin/main`
at `eda6428`. The experience work is a presentation-layer adaptation of the
completed Tunix design; it is not a replacement of the canonical evidence or
release architecture.

## Product surface

- Overview is the executive read: current condition, recent evidence-backed
  changes, bounded performance trend, battery and storage summaries, and clear
  investigation routes.
- Cooling remains an advanced read-only destination and command route. It is
  not a default sidebar item, so the primary navigation stays focused on the
  everyday overview.
- System Health keeps current telemetry separate from captured evidence and
  exposes Cooling Details only when the canonical cooling service has usable
  readings. Unavailable fan or temperature data is described as unavailable,
  never as proof that hardware is absent or healthy.

## Evidence language

Capture status is presentation-only vocabulary over the canonical
`IncidentCaptureStatus` and package persistence:

- `complete` is shown as “Captured successfully”.
- `incomplete` is shown as “Captured with limitations”, with an explicit
  coverage limitation and the statement that missing evidence is not proof
  that an event did not occur.
- A capture with no qualifying observations says that no qualifying change was
  captured in the window; it does not claim that nothing changed.

The export schema, redaction manifest, source manifest, package assembly, and
sandbox-safe save path remain canonical and unchanged by this experience work.

## Distribution boundary

The integration does not change entitlements, telemetry providers, release
scripts, App Store compilation conditions, or submission behavior. Battery
temperature is not promoted into the Overview executive surface; detailed
battery and cooling diagnostics remain behind their existing read-only
destinations and preserve their availability semantics.

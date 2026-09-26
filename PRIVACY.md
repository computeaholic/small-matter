# Small Matter Privacy

Small Matter is a local macOS application. It does not send telemetry or
support data to a company service.

## What stays local

- CPU, memory, network, storage, battery, cooling, and thermal observations
- local application settings and compatibility state
- user-scoped Cleanup quarantine and undo state
- Keep Awake assertion state while the app is running
- diagnostic and System Health information

The app contains no analytics SDK, tracking identifier, cloud synchronization,
AI processing service, or advertising integration.

## Support snapshots

Support snapshots are created only when the user requests an export. They are
structured summaries of application identity, telemetry status, capabilities,
timestamps, and relevant diagnostic state. They are not automatic uploads.

Snapshots intentionally avoid passwords, tokens, private file contents, and
unnecessary personal identifiers. Review an exported snapshot before sharing
it.

## Hardware and files

Hardware observation is read-only. macOS remains responsible for fan behavior,
thermal response, charging, and battery-protection policy. Cleanup operates
only on user-scoped paths and uses quarantine/undo rather than silent
destructive deletion.

For questions about a local export, remove the file if it is no longer needed.

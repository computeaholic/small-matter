# Small Matter Privacy

**Small Matter keeps system observations local.** There is no Small Matter account, cloud telemetry service, advertising, analytics, or tracking SDK. The app does not send your measurements or evidence to a company service.

## Information that stays on your Mac

- CPU, memory, network, storage, battery, cooling, and thermal observations.
- Recent Changes history, incident captures, and their bounded evidence journal.
- App settings, compatibility state, and Keep Awake state while running.
- User-directed evidence and support exports stored at destinations you choose.

Small Matter may retain a bounded local history to support investigation. If that journal becomes full, collection can be limited. Historical captures are not automatically uploaded.

## Exports and sharing

Small Matter creates support and evidence files only when you request them. Exported files may contain time stamps, system measurements, and evidence context. The export process applies privacy-conscious redaction, but **review the contents before sharing** them with anyone.

The app does not automatically send those files to its developer or to third parties.

## Hardware and permissions

Hardware telemetry is read-only. macOS retains control over fans, thermal response, charging, and battery-protection policy. Hardware readings may be unavailable on some Macs or in App Sandbox; Small Matter labels unsupported or missing readings accordingly.

The Mac App Store distribution uses App Sandbox and user-selected file access for exports. Cleanup in that distribution is conservatively limited to qualified Small Matter-owned disposable data; it does not perform broad system-cache deletion, arbitrary selected-folder permanent deletion, or Xcode Derived Data cleanup.

Separate direct-distribution builds may have different capabilities. They should not be confused with those of the Mac App Store app.

## Support

For documentation and questions, visit the [Small Matter support page](https://computeaholic.github.io/small-matter/). If you report an issue publicly, **do not include passwords, access tokens, unredacted exports, serial numbers, or private file contents**.

[Get Small Matter on the Mac App Store](https://apps.apple.com/us/app/small-matter/id6819082403).

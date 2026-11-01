# Small Matter

<img src="Tunix/Brand/SmallMatterIcon.svg" width="112" height="112" alt="Small Matter app icon">

**See what your Mac is doing. Understand what changed. Keep your data yours.**

Small Matter is a native macOS performance and system-observation app. It makes the activity behind your Mac easier to understand: a clear, live view of CPU, memory, and network performance, with useful history and evidence when something catches your attention.

No account. No advertising, analytics, tracking, or cloud telemetry. Your observations stay on your Mac unless you choose to export them.

**[Get Small Matter free on the Mac App Store](https://apps.apple.com/us/app/small-matter/id6819082403)** · [Support and troubleshooting](https://computeaholic.github.io/small-matter/) · [Report an issue](https://github.com/computeaholic/small-matter/issues)

## See your Mac at a glance

The performance-first Overview makes the important information easy to find:

- **CPU:** current utilization and a short, bounded activity history.
- **Memory:** current use, pressure, compression, cache, and swap.
- **Network:** live download and upload rates with recent throughput history.
- **Battery and power:** charge, health, cycle count, capacity, and available electrical readings.
- **Storage and thermals:** available disk space, macOS thermal pressure, and supported cooling observations.

All readings are sourced from the Mac. **Unavailable, stale, and actual zero readings are different states**—Small Matter does not invent measurements to fill gaps.

## Understand what changed

A snapshot tells you what is happening now. Small Matter also helps you investigate what happened around it.

**Recent Changes** presents supported observations about storage, power, and network transitions, including the evidence behind them and any known gaps. **Incident Capture** saves a bounded window around a moment you want to examine. Reopen the capture, inspect its context, and export your own text or JSON evidence package.

Evidence is stored locally with bounded retention and safeguards for protected captures. If storage capacity limits collection, the app explains that limitation rather than implying everything was recorded.

## Private by design

- **Local-first:** no Small Matter account, analytics SDK, advertising, tracking, or background cloud upload.
- **Read-only hardware observation:** macOS retains control of fans, thermal response, charging, and battery-protection policy.
- **User-directed exports:** evidence files are created only when you choose to save them. Review files before sharing.
- **Honest sensor limitations:** some hardware readings are unavailable on certain Macs or within App Sandbox.

### A note on Cleanup

The **Mac App Store build** deliberately limits Cleanup to qualified Small Matter-owned disposable data; it does **not** offer broad system-cache sweeping, Xcode Derived Data deletion, or unqualified user-selected permanent deletion. This is not a general-purpose disk cleaner.

The separately configured **Developer ID** build has different qualified capabilities. Do not assume that a capability documented for one distribution exists in the other.

## Install and support

- [Download on the Mac App Store](https://apps.apple.com/us/app/small-matter/id6819082403) (Free)
- [Support, setup, and common questions](https://computeaholic.github.io/small-matter/)
- [Issues and feature requests](https://github.com/computeaholic/small-matter/issues)
- [Privacy](PRIVACY.md) · [Security](SECURITY.md) · [App Store capability matrix](docs/APP_STORE_TELEMETRY_MATRIX.md)

Requires **macOS 15.5 or newer**. Native universal build for Apple Silicon and Intel Macs. The App Store controls which app version is currently available in each territory; this repository's source and release work may be newer than the public listing.

## Development

Small Matter was developed under the codename **Tunix**. Its Xcode project, Swift module, bundle identifier, and existing persistence paths intentionally retain those identifiers for compatibility.

Open **Tunix.xcodeproj** in Xcode. The source tree contains separate **Mac App Store** and **Developer ID** configurations.

Quality and release verification:

    ./scripts/run_tunix_app_unit_tests.sh --fresh-derived-data
    ./scripts/run_tunix_ui_tests.sh --fresh-derived-data
    swiftformat Tunix TunixTests TunixUITests --lint
    swiftlint lint Tunix TunixTests TunixUITests --reporter json
    zsh -n scripts/*.sh
    ./scripts/build_release.sh --prepare-only
    ./scripts/verify_release_artifact.sh --allow-unsigned \
      --app '.deriveddata/release/Build/Products/Release/Small Matter.app'
    git diff --check

Full macOS UI testing is a local release gate because hosted CI does not provide deterministic interactive Automation permissions. Build 12's source qualified with **35 passing UI tests**. Signed uploads, notarization, and App Store review require the corresponding Apple distribution credentials and approvals.

For deeper technical detail, see [Architecture](ARCHITECTURE.md), [Release checklist](docs/RELEASE_CHECKLIST.md), and [Source provenance](PUBLIC_SOURCE_PROVENANCE.md). App Store merchandising drafts and claim boundaries are tracked in [App Store product-page copy](docs/APP_STORE_PRODUCT_PAGE.md).

## License

Small Matter is **source-available**, licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). This is not an OSI-approved open-source license.

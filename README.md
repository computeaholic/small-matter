# Small Matter

Small Matter is a native macOS system-monitoring and utility app built around
precise observation, least privilege, and minimal interference.

The app provides local CPU, memory, network, storage, battery, cooling, and
thermal telemetry; readable System Health diagnostics; a privacy-preserving
support snapshot; explicit Keep Awake; and user-scoped cleanup with quarantine
and undo.

Small Matter runs as the logged-in user. It has no privileged helper, root
daemon, cloud service, analytics, tracking, or AI integration. Hardware
telemetry is read-only: macOS remains responsible for fan speed, thermal
response, charging, and battery-protection policy.

## Product principles

- Observe precisely.
- Interfere as little as possible.
- Present the machine clearly.

Unknown, unavailable, and valid zero values remain distinct. When a native
source cannot prove a capability or produce a valid sample, Small Matter shows
that state rather than inventing a plausible value.

## Current capabilities

- CPU utilization and bounded history
- memory use, pressure, compression, cache, and swap
- native interface network throughput
- battery charge, health, cycles, voltage, current, power, and temperature
- read-only AppleSMC fan RPM, bounds, and supported temperature readings
- macOS thermal pressure
- storage capacity telemetry
- System Health diagnostics and support snapshot
- user-scoped cleanup with quarantine and undo
- app-scoped Keep Awake using a native power-management assertion

Raw AppleSMC sensor availability is hardware-dependent. Fan write support is
intentionally unproven and absent from the product. Battery-policy control and
arbitrary SMC writes are also absent.

## Build and validation

Small Matter requires macOS 15.5 or newer and Xcode 16.4 or newer. Open
`Tunix.xcodeproj` in Xcode and run the internal `Tunix` scheme. The built
application and public product name are **Small Matter**; the project, target,
Swift module, bundle identifier, and persistence paths retain their Tunix-era
identifiers for compatibility.

For deterministic local validation:

```bash
./scripts/run_tunix_app_unit_tests.sh --fresh-derived-data
./scripts/run_tunix_ui_tests.sh --fresh-derived-data
swiftformat Tunix TunixTests TunixUITests --lint
swiftlint lint Tunix TunixTests TunixUITests --reporter json
zsh -n scripts/*.sh
./scripts/build_release.sh --prepare-only
./scripts/verify_release_artifact.sh --allow-unsigned \
  --app '.deriveddata/release/Build/Products/Release/Small Matter.app'
git diff --check
```

For authorized direct distribution, use the same build path with a Developer
ID Application identity, then submit the resulting ZIP through a Keychain-only
`notarytool` profile:

```bash
./scripts/build_release.sh --signed
TUNIX_NOTARYTOOL_PROFILE=<keychain-profile> \
  ./scripts/notarize_release.sh \
  --app '.deriveddata/release/Build/Products/Release/Small Matter.app'
```

The notarization script staples the accepted ticket, recreates the final ZIP
and SHA-256 checksum, and validates the extracted archive with Gatekeeper.

See `ARCHITECTURE.md`, `SECURITY.md`, `PRIVACY.md`, and
`docs/RELEASE_CHECKLIST.md` for current technical and release truth.

Small Matter was developed under the codename Tunix.

The stable project, module, bundle, and persistence identifiers intentionally
retain that internal codename for compatibility. They are not the public
product name.

## Release status

Small Matter `0.9.1` is the published direct-distribution release. The
repository contains separate Developer ID and Mac App Store build
configurations; the latter uses App Sandbox and has its own publishing state.
Historical release tags and assets are immutable. Local unsigned Release
builds and artifact verification remain reproducible. Developer ID signing and
notarization require the authorized Apple credentials and are reported only
when the actual artifact has been accepted by Apple and Gatekeeper.

The full UI test command remains a mandatory local release gate because
GitHub-hosted runners do not provide deterministic interactive Automation
permissions:

```sh
./scripts/run_tunix_ui_tests.sh --fresh-derived-data
```

## License

Small Matter is licensed under the PolyForm Noncommercial License 1.0.0.
This is a source-available noncommercial license, not an OSI-approved
open-source license. See `LICENSE` for the complete terms.

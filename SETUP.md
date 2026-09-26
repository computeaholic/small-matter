# Small Matter Setup and Deployment

## Prerequisites

- macOS 15.5 or newer
- Xcode 16.4 or newer
- SwiftFormat and SwiftLint for local quality checks
- An Apple Developer ID Application identity only for signed distribution

## Local development

Open `Tunix.xcodeproj`, select the internal `Tunix` scheme, and run on My Mac.
The Xcode project, target, Swift module, and source directory keep the Tunix
codename for compatibility; the built app is named **Small Matter**.

For an unsigned command-line build:

```bash
xcodebuild \
  -project Tunix.xcodeproj \
  -scheme Tunix \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Small Matter is one normal-user application. There is no helper target,
LaunchDaemon, privileged XPC service, ServiceManagement registration, or app
group requirement.

## Validation

```bash
swiftformat Tunix TunixTests TunixUITests --lint
swiftlint lint Tunix TunixTests TunixUITests --reporter json
./scripts/run_tunix_app_unit_tests.sh --fresh-derived-data
./scripts/run_tunix_ui_tests.sh --fresh-derived-data
./scripts/build_release.sh --prepare-only
./scripts/verify_release_artifact.sh --allow-unsigned \
  --app '.deriveddata/release/Build/Products/Release/Small Matter.app'
zsh -n scripts/*.sh
git diff --check
```

These paths intentionally retain the development codename because they are
internal interfaces used by Xcode, CI, and existing developer tooling.

## Release preparation

`scripts/build_release.sh --prepare-only` creates an unsigned local validation
artifact named `Small-Matter-VERSION-BUILD-macos.zip`. It is not a distributable
release and is not evidence of Gatekeeper acceptance.

Signed distribution requires an authorized Developer ID Application identity
and a `notarytool` Keychain profile. Follow `docs/RELEASE_CHECKLIST.md`; never
commit signing or notarization credentials.

## Product boundary

Cooling and battery telemetry are read-only. macOS owns fan speed, thermal
response, charging, and battery-protection policy. Do not add physical mutation
tests, undocumented SMC writes, or privileged services as part of setup.

User-scoped Cleanup is the only file-mutating product surface. It uses the
stable Application Support path retained from the Tunix codename so existing
quarantine and undo data remain available after the public rename.

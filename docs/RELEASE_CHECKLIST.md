# Small Matter Release Checklist

This checklist is for the direct-distribution macOS artifact. Small Matter is a
read-only monitor: release validation must not invoke fan, battery-policy, or
arbitrary SMC writes.

## Version and source

- [ ] Confirm the intended `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- [ ] Confirm the release commit, clean worktree, and reviewed release notes.
- [ ] Confirm the app is the only product executable and no background service is embedded.
- [ ] Confirm no Debug-only test hooks or physical-mutation tests are selected.

## Build and signing

- [ ] Run `scripts/build_release.sh --signed` with a Developer ID Application
      identity from the release keychain.
- [ ] Confirm the app uses the expected Team ID and Developer ID signing
      identity.
- [ ] Confirm Release uses hardened runtime and no development entitlements.
- [ ] Run `scripts/verify_release_artifact.sh --app 'path/to/Small Matter.app'`.
- [ ] Confirm no LaunchDaemon plist or privileged Mach-service payload is embedded.

For local validation without release credentials, use
`scripts/build_release.sh --prepare-only` and treat the result as unsigned
preparation only. It is not a shippable artifact.

## Notarization and packaging

- [ ] Store notarization credentials only in Keychain via `notarytool`.
- [ ] Run `TUNIX_NOTARYTOOL_PROFILE=name scripts/notarize_release.sh
      --app 'path/to/Small Matter.app'`.
- [ ] Confirm stapler validation and Gatekeeper assessment succeed. The
      notarization script checks the extracted final ZIP, not only the build
      directory copy.
- [ ] Publish the notarized ZIP and its SHA-256 file together.
- [ ] Test the exact ZIP on a clean macOS user account or clean machine.

## Runtime and safety gates

- [ ] Launch the app and confirm native CPU, memory, network, battery, storage,
      and thermal-pressure views remain useful.
- [ ] Confirm first launch requires no privileged-service installation or approval.
- [ ] Exercise sleep/wake, close/reopen, Settings, cleanup confirmation, and
      support-snapshot copy behavior.
- [ ] Review light, dark, increased-contrast, larger-text, and 1440 x 900
      layouts.
- [ ] Run the release soak for at least 30 minutes and record CPU, RSS, timer
      count, and recovery observations.
- [ ] Confirm the security review finds no fan write, battery-policy write, or
      arbitrary SMC write path.

## Quality gates

- [ ] `swiftformat Tunix TunixTests --lint`
- [ ] `swiftlint lint Tunix TunixTests --reporter json`
- [ ] `scripts/run_tunix_app_unit_tests.sh`
- [ ] Unsigned Debug and unsigned Release preparation builds
- [ ] `git diff --check`
- [ ] No unexpected compiler warnings

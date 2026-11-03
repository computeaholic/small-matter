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
- [ ] Confirm `scripts/verify_app_store_export_compliance.sh` reports
      `APP_STORE_NONEXEMPT_ENCRYPTION=NO` for Mac App Store builds. This
      declaration covers the current CryptoKit SHA-256 hashing/redaction use;
      re-audit before adding any encryption or cryptographic transport.
- [ ] Confirm no LaunchDaemon plist or privileged Mach-service payload is embedded.

For local validation without release credentials, use
`scripts/build_release.sh --prepare-only` and treat the result as unsigned
preparation only. It is not a shippable artifact.

## Notarization and packaging

- [ ] Run `scripts/build_release.sh --signed --direct-dmg` from a clean review
      checkout. This creates a new DMG only; it does not publish or install it.
- [ ] Confirm the DMG contains only `Small Matter.app` and `Applications ->
      /Applications` (plus Finder metadata), and that the checked-in app icon
      is present in the app bundle.
- [ ] Confirm the DMG manifest records `FORMAT=UDZO`, zlib level 9, the
      symlink target, app file hashes, and the Finder layout result.
- [ ] Confirm the DMG checksum and manifest checksum validate.
- [ ] Run `scripts/verify_direct_dmg.sh --dmg 'path/to/Small-Matter.dmg'`.
- [ ] Store notarization credentials only in Keychain via `notarytool`.
- [ ] Run `TUNIX_NOTARYTOOL_PROFILE=name scripts/notarize_direct_dmg.sh
      --dmg 'path/to/Small-Matter.dmg'`.
- [ ] Confirm stapler validation and Gatekeeper assessment succeed against the
      app mounted from the stapled DMG.
- [ ] Record `NOTARIZATION_UNAVAILABLE` if the safe Keychain profile is absent;
      do not call the DMG notarized.
- [ ] Test the exact DMG on a clean macOS user account or clean machine.
- [ ] Run `scripts/test_direct_dmg.sh` and retain its pass/failure receipt.

The DMG workflow promises repeatable logical volume contents and explicit
checksums. `hdiutil` filesystem/container metadata and Finder `.DS_Store` can
introduce byte-level variation, so bitwise determinism is not claimed.

The older ZIP/notarization scripts remain for their existing artifact contract;
they do not qualify a direct-distribution DMG.

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

## App Store storefront metadata and assets

- [ ] Confirm subtitle is exactly `Performance without guesswork` to avoid a
      repeat of Guideline 5.2.5 rejection.
- [ ] Confirm App Store metadata edits are attempted only in an Apple-allowed
      state (do not disrupt a `Waiting for Review` / `In Review` submission).
- [ ] Confirm promotional text length (`<=170`) and keyword bytes (`<=100`) for
      the final copy in `docs/APP_STORE_PRODUCT_PAGE.md`.
- [ ] Generate screenshot packet via
      `scripts/prepare_app_store_screenshots.sh` and keep `manifest.json` with
      SHA-256 values for every uploaded screenshot.
- [ ] Confirm screenshot provenance is authentic Small Matter app UI from the
      intended version/build (no mockups, fabricated values, or unsupported
      capability claims).
- [ ] Complete manual visual review on macOS for private-data exposure
      (serials, usernames, paths, tokens) before upload.

## Quality gates

- [ ] `swiftformat Tunix TunixTests --lint`
- [ ] `swiftlint lint Tunix TunixTests --reporter json`
- [ ] `scripts/run_tunix_app_unit_tests.sh`
- [ ] Unsigned Debug and unsigned Release preparation builds
- [ ] `git diff --check`
- [ ] No unexpected compiler warnings

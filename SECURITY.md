# Small Matter Security

Small Matter follows a least-authority, normal-user architecture. The app owns
its UI, local telemetry, read-only sensor access, diagnostics, Keep Awake
assertion, and explicit user-scoped Cleanup operations.

It does not install or communicate with a privileged helper, root daemon,
LaunchDaemon, or privileged XPC service. It has no cloud, analytics, tracking,
or AI integration.

## Hardware policy boundary

Production contains no fan-mode, fan-target, Ftst, charge-policy, or arbitrary
SMC write operation. macOS owns fan speed, thermal response, charging, and
battery-protection policy. Unsupported telemetry is reported as unavailable;
successful readback never implies write support.

## Local operations

Cleanup is user-directed and limited to configured user-scoped locations.
Eligible items are staged in quarantine before removal and recorded for undo.
Denied paths fail normally under the logged-in user's macOS permissions.

Keep Awake uses an app-scoped native power-management assertion. It is off at
launch, is not persisted, and is released when disabled or when the app exits.

## Support and disclosure

This repository does not currently publish a dedicated security-reporting
address. Do not include credentials, private logs, or personal data in an issue
or support snapshot. A public disclosure contact will be added if one is
established.

## Compatibility identifiers

The bundle identifier, logging subsystem, persisted preference keys, and
Application Support paths retain Tunix-era identifiers. They are internal
compatibility values, not public product naming, and prevent upgrades from
losing settings or quarantine history.

Historical implementation details are not current product capabilities. The
public product boundary is the read-only, unprivileged architecture described
above.

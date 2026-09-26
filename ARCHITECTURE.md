# Small Matter Architecture

Small Matter is a read-only macOS systems monitor. It runs as the logged-in user,
observes hardware and system state, and leaves thermal and battery policy with
macOS. There is no privileged background service or XPC boundary.

## Production pipeline

```text
Small Matter.app (normal user process)
  ├─ Mach APIs                         CPU / memory
  ├─ native interface counters        network
  ├─ IOPowerSources / IORegistry      battery
  ├─ AppleSMC read-only               cooling / sensors
  ├─ ProcessInfo                      thermal state
  ├─ filesystem APIs                  storage telemetry
  └─ user-scoped FileManager          cleanup / quarantine / undo
          │
          ▼
      Collectors
          │
          ▼
    Normalization and validation
          │
          ▼
    Immutable domain snapshots
       ┌──┴──┐
       ▼     ▼
    History Health / freshness
       └──┬──┘
          ▼
    MainActor presentation models
          │
          ▼
        SwiftUI
```

Collection and normalization can run away from the main actor. Published state
crosses one deliberate MainActor boundary. Views do not own telemetry timers or
history.

## Domain audit

| Domain | Collector / raw source | Snapshot and publication | Cadence / history | Failure behavior |
| --- | --- | --- | --- | --- |
| CPU | Mach processor statistics | CPUSnapshot in SystemTelemetrySnapshot | 1 s / 60 samples | Invalid deltas retain the last coherent sample |
| Memory | Mach VM statistics and pressure events | MemorySnapshot in SystemTelemetrySnapshot | 1 s / 60 samples | Invalid reads retain the last sample |
| Network | Native interface counters | NetworkSnapshot in SystemTelemetrySnapshot | 1 s / 60 samples | First sample has no invented rate |
| Cooling | Read-only AppleSMC and ProcessInfo thermal state | Immutable CoolingSnapshot from CoolingService | 3 s / bounded current state | Last good read is retained through transient failure |
| Thermal | ProcessInfo.thermalState | SystemThermalSnapshot | 1 s local state | macOS thermal pressure remains available when raw sensors do not |
| Battery | IOPowerSources and AppleSmartBattery IORegistry | BatterySnapshot | 5 s / bounded current state | Last good sample becomes stale, then unavailable |
| Storage | Filesystem attributes | StorageSnapshot | 1 s / no persistent telemetry history | Missing attributes are unavailable, not zero |
| Cleanup | User-scoped FileManager operations | DiskTool action ledger and intent log | Explicit user action | Denied paths fail normally; quarantine supports undo |
| System Health | App-owned domain snapshots | MainActor presentation and support snapshot | Event-driven | Source, freshness, age, and failures remain visible |

## Shared semantics

`TelemetryModels.swift` contains the shared vocabulary:

- `TelemetryFreshness`: fresh, stale, or unavailable.
- `TelemetrySource`: provenance of an observation.
- `TelemetryHealth`: last attempt, last success, failure count, and thresholds.
- `BoundedHistory`: capped, timestamp-preserving samples.
- `TelemetryErrorKind`: stable diagnostic categories.

Domains retain their own state machines where hardware semantics differ, while
sharing freshness, provenance, zero/unknown/unavailable, and last-good behavior.
Every metric distinguishes a legitimate zero from unknown and unavailable.
Canonical units are bytes, bytes/second, percent, RPM, degrees Celsius,
millivolts, milliamps, and watts.

## Sampling and lifecycle

- `SystemStatsModel`: one 1-second timer for CPU, memory, network, storage, and local thermal state.
- `CoolingService`: one 3-second app-process AppleSMC read loop.
- `BatteryManager`: one 5-second native battery loop.
- Memory pressure: one event source.

Views contain no domain polling timers. Foreground and wake activity resumes the
same owned loops. No privileged reconnect or manual refresh is required.

## User-directed Cleanup

Cleanup is the only file-mutating product surface. It scans configured paths,
requires explicit confirmation before staging, moves eligible files into the
user's Small Matter Quarantine surface, records an intent and action ledger, and
supports undo. It never escalates through sudo, Authorization Services, launchd,
or a root process. System-owned paths may fail due to normal macOS permissions.

Small Matter currently has no mount, unmount, erase, partition, SMART, filesystem
repair, volume-ownership, or raw-device operation.

## System Health and support snapshot

System Health reports application state, telemetry-domain status, freshness,
source, sample age, failures, and policy boundaries. Its deterministic support
snapshot contains application, telemetry, security, and policy objects.
The security object records `executionModel: unprivileged`,
`privilegedHelper: false`, and `hardwareWrites: false`. No nonexistent service
or XPC schema is emitted.

## Security boundary

Small Matter has no privileged XPC endpoint, launch daemon, ServiceManagement
registration, Authorization Services path, root subprocess, arbitrary SMC
command, fan write, or battery-policy write. The app entitlements remain empty
and Release keeps Hardened Runtime enabled without adding exceptions.

macOS owns thermal and charging policy. Fan read availability, fan bounds
availability, and experimental/unproven write capability remain separate; the
write capability is absent from the product.

## macOS interaction model

`SmallMatterApp` owns the monitoring window and native Settings scene. Navigation
state is the only custom-persisted UI state. Monitoring state and transient
failures are not persisted. System Health and Settings describe the actual
normal-user, read-only architecture without installation or approval steps.

## Visual direction

Small Matter uses a quiet, precise, technical visual language: dense enough for a
systems monitor, but calm enough to read as a native macOS utility rather than
a dashboard. Shared panels, metric rows, status badges, monospaced numeric
values, restrained semantic color, and consistent empty states provide the
common grammar. Domain screens keep their own information hierarchy instead of
turning every value into an equal card.

The shared layout tokens are a 28-point page inset, 26-point section spacing,
16-point group spacing, 10-point row spacing, 14-point panel corners, 20-point
panel padding, and a 156-point standard chart height. Overview is intentionally
executive; Performance is chart-led; Cooling is trust-led; Battery is organized
around Charge, Health, and Electrical; Cleanup follows Scan, Review, Stage, and
Undo; System Health is the advanced operational surface; Settings contains only
real controls in the native Settings scene. Screen-specific maximum widths keep
wide windows readable while the shared sidebar remains keyboard navigable.

## Product identity, adaptive layout, and Keep Awake

Public-facing identity is defined in `ProductIdentity.swift`. Views, About,
support exports, and user-facing copy consume that identity instead of
inventing their own product name. Stable storage identifiers remain explicit
and unchanged (`Tunix`, `Tunix-LLC.Tunix`, and `com.tunix`) so the public rename
does not strand settings, quarantine state, or other local data. These values
retain the former development codename intentionally.

Brand treatment is intentionally restrained: native graphite surfaces, a cool
accent, a secondary chart accent, semantic healthy/warning/critical colors,
and a small waveform motif used as a signal rather than a decorative logo.
`TunixAdaptivePage` derives a layout class from available width:

| Layout class | Detail width | Intent |
| --- | ---: | --- |
| Compact | < 1100 pt | Single-column reading order |
| Standard | 1100–1399 pt | Familiar two-column groups where useful |
| Wide | 1400–1699 pt | Bounded multi-column desktop composition |
| Large | ≥ 1700 pt | Wider composition with capped readable groups |

Settings remains a compact native Settings surface. Monitoring pages choose
their own composition within the shared class rather than stretching a common
card grid indefinitely.

Keep Awake is an explicit, app-scoped read-only system assertion implemented
by `KeepAwakeController` through
`IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)`.
It has no helper, daemon, shell command, privilege escalation, or persistence.
The default is off for every launch; disabling it and application termination
release the assertion immediately. The controller is MainActor-owned and its
assertion backend is injectable for deterministic tests.

The AppIcon asset catalog is kept as a brand-ready pipeline rather than a
premature final logo. A final macOS icon should provide the standard 16, 32,
128, 256, and 512 point slots at 1x and 2x, with the macOS icon idiom and any
light/dark or tinted variants adopted as a deliberate follow-up.

## Durable decisions

- ADR-001 records hardware policy ownership.
- ADR-002 records the move of cooling telemetry into the normal-user app process.
- ADR-003 records removal of the unnecessary privileged helper.

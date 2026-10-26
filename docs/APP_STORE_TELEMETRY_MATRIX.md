# App Store telemetry qualification

Measured on 2026-10-26 on the owner's physical Apple Silicon MacBook Pro
(Mac16,5, Apple M4 Max, macOS 27.0.1, arm64). No serial numbers or personal
identifiers are recorded here. These results describe this hardware and build
boundary; they are not a universal claim about every Apple Silicon Mac.

The App Store candidate was built with the `SmallMatter-AppStore` scheme,
`MacAppStore` configuration, App Sandbox, and the existing read/write
user-selected-file entitlement. The installed 1.0 (6) application was not
replaced during diagnosis.

| Feature | Host source | Sandboxed result | Fallback | Final UI | Status |
| --- | --- | --- | --- | --- | --- |
| Battery percentage | AppleSmartBattery / IOPowerSources | 80% observed | IOPowerSources charge percentage | 80% | `SUPPORTED_AND_VERIFIED` |
| Charging / AC state | AppleSmartBattery / IOPowerSources | AC connected, not charging observed | IOPowerSources power-source state | Connected to Power | `SUPPORTED_AND_VERIFIED` |
| Battery voltage | AppleSmartBattery `Voltage` / `AppleRawBatteryVoltage` | 12,286 mV observed | IOPowerSources voltage | 12.29 V | `SUPPORTED_AND_VERIFIED` |
| Battery current | AppleSmartBattery `InstantAmperage` / `Amperage` | 0 mA observed | IOPowerSources current | 0.00 A | `SUPPORTED_AND_VERIFIED` |
| Battery power | Derived from compatible voltage and signed current | 0.0 W observed | None; no inference from charge percentage | 0.0 W | `SUPPORTED_AND_VERIFIED` |
| Battery temperature | AppleSMC outside the sandbox; no public battery-temperature value observed in the sandbox | AppleSMC path unavailable to the App Store build | None | Unavailable with a sandbox-compatible explanation | `UNAVAILABLE_BY_SANDBOX` |
| Time to empty / full | AppleSmartBattery estimate keys | Sentinel values while connected and not charging; no estimate observed | None; no synthetic estimate | Not discharging / Not charging | `SUPPORTED_NOT_OBSERVED` |
| Battery health / cycles | AppleSmartBattery capacities and cycle count | 98%, 24 cycles, 8419 mAh maximum, 8579 mAh design observed | IOPowerSources for charge state only | Health and capacity cards | `SUPPORTED_AND_VERIFIED` |
| macOS thermal state | `ProcessInfo.processInfo.thermalState` | Nominal observed independently of sensor polling | Thermal-state notification plus bounded refresh | Thermal Nominal / Normal | `SUPPORTED_AND_VERIFIED` |
| Fan count / RPM | AppleSMC read-only service in direct build | Direct build observed 2 fans; App Store build cannot use the private service | None | Unavailable with App Store capability explanation | `UNAVAILABLE_BY_SANDBOX` |
| Hardware temperatures | AppleSMC read-only keys in direct build | Direct build observed supported temperatures; App Store build cannot use the private service | None | Unavailable; thermal state is not relabeled as Celsius | `UNAVAILABLE_BY_SANDBOX` |

## Before and after

The installed App Store application and the first sandboxed diagnostic build
already demonstrated that the public battery path could provide percentage,
AC state, voltage, current, power, health, and cycles. The repaired candidate
keeps those values, preserves signed current and per-field provenance, rejects
sentinel time estimates, and explains the temperature boundary.

The material Cooling repair is independent thermal-state presentation: the
Overview and Cooling surfaces now show the observed macOS thermal state even
when raw fan and temperature access is unavailable. The candidate does not
invent fan RPM or Celsius readings.

The direct Developer ID comparison remains a separate capability boundary. It
continues to read the established AppleSMC fan and temperature values, while
the App Store configuration excludes that private user-client implementation.

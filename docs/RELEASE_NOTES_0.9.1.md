# Small Matter 0.9.1 (2)

Small Matter is a native, local-first macOS monitor for understanding the
machine without taking ownership of macOS policy.

## Included

- Native storage inventory and Recent Changes semantics with explicit source
  and freshness context
- Clearer incident capture context, change summaries, and safe incomplete
  export behavior when a capture cannot reach a complete quiet boundary
- CPU, memory, network, storage, battery, cooling, and thermal telemetry
- System Health diagnostics and privacy-preserving support snapshot export
- Explicit Keep Awake control and user-scoped Cleanup preview with quarantine
  and undo workflow
- Read-only hardware observation; macOS remains responsible for thermal and
  charging policy

Small Matter has no privileged helper, cloud service, analytics, tracking, or
AI integration. Distribution signing, notarization, and Gatekeeper status are
release-artifact properties and must be reported from the actual artifact.

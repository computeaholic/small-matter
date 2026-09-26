# Contributing

## Standards

- Keep changes minimal, deterministic, and reviewable.
- Avoid hidden behavior and implicit network access.
- Preserve the normal-user, read-only hardware boundary.
- Every user-visible action must be explainable.

## Development flow

The private Tunix repository is the canonical engineering source. Public
Small Matter exports are curated snapshots and are not independently
developed. Changes intended for the public product originate in Tunix, pass
validation, and are exported deliberately.

Use focused branches and conventional commit subjects such as:

- `feat(ui): ...`
- `fix(telemetry): ...`
- `test: ...`
- `docs: ...`

## Review requirements

Pull requests should include a clear summary, risk notes, and exact test
commands. Do not include credentials, local machine data, generated artifacts,
or private development context.

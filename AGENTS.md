# Nuncid — Agent Doctrine Overlay

This file contains the Nuncid-specific delta. Universal INSPR doctrine lives in
the `doctrine/` submodule (`inspr-at/inspr-modules`); load the relevant domain
pack from `doctrine/docs/` before specialized work. This is a public repository:
it vendors the public doctrine only. The private operator pack
(`inspr-at/inspr-doctrine-private`) is studio repos only — never vendor it here.

## Project identity

- **Trust context**: personal, published FOSS (AGPL-3.0 under `markus-barta`);
  member of the INSPR product family (Paimos, Janus, Pharos, …).
- **PPM project**: Nuncid, key `NUNCID` on instance `ppm`.
- Use `paimos` for Knowledge, backlog, ticket status, and time tracking.
- Reference `NUNCID-<number>` in branches, commits, pull requests, and reports.

## Repository boundaries

- Nuncid owns the macOS menu-bar ticket-context app: hover/OCR, parsing,
  resolution, shortcuts, UI, packaging, and release tooling.
- It is deliberately small, local-first, and read-only toward its trackers:
  it launches only local read-only `paimos` and `gh` commands and never writes
  to either service. Private-by-construction (no pixels, OCR text, or ticket
  content leave the process; no telemetry) is a product constraint, not a
  missing feature.
- Paimos project routes are discovered from configured local profiles by
  `Sources/Nuncid/TrackerDirectory.swift`; Settings manages participating
  instances. GitHub repository hints live in `TokenParser.swift`.
- Durable architecture and product knowledge belongs in PPM Knowledge
  (`NUNCID` project). Local documentation stays within the standard repository
  files described by doctrine.

## Local validation

- Keep agent test/probe windows on the MacBook's built-in display, never over
  the operator's Studio display work windows. Resolve the built-in display ID
  at runtime and set `NUNCID_PROBE_DISPLAY_ID` for UI checks; do not assume a
  fixed display ID. If it is unavailable, keep visual probes closed and ask.

```sh
./scripts/test.sh                                  # build, self-tests, versioning regression
./scripts/check-release-consistency.sh             # README, changelog, history, visual parity
./scripts/package-release.sh && ./scripts/verify-release.sh   # release gates
```

- Swift 5.10 toolchain, macOS 13+; 1.0 remains in Swift 5 language mode and
  treats warnings as errors in the supported build mode.
- `VERSION` is the source of truth for the packaged version; keep it and
  `CHANGELOG.md` in sync through `./scripts/bump-version.sh`.
- Packaging defaults to local ad-hoc signing; Developer ID + notarization is
  opt-in via `NUNCID_SIGNING_IDENTITY` / `NUNCID_NOTARY_PROFILE` and is never
  exercised by CI.

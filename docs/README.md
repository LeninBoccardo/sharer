# Sharer — Versioned Documentation

Living spec for the app. Each `vN/` folder is the authoritative source for the design of that version.

## Conventions

- One folder per app version: `v1/`, `v2/`, …
- Inside each version folder, split by concern:
  - `overview.md` — what this version delivers, scope cuts
  - `architecture.md` — subsystems, data flow
  - `security.md` — pairing, signatures, kill-switch
  - `ux.md` — flows, screens, click-budgets
  - `open-questions.md` — unresolved design calls (clear out as decided)
- When a doc in a newer version supersedes one in an older version, link back from the new doc; do not edit the old version's docs in place. Older `vN/` folders are frozen as historical record once the version ships.
- The original brainstorm at the repo root ([../APP_INITIAL_DOCS.md](../APP_INITIAL_DOCS.md)) is preserved as historical context — `docs/v1/` overrides anywhere they conflict.

## Versions

- [v1/](v1/) — first shippable version. Status: in design.

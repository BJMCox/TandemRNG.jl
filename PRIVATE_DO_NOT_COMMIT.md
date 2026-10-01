# Private files: do not commit or publish

This list is private. Keep it outside Git and all public release assets.
Do not add these paths to the public `.gitignore`.

## Private documents

- `PRIVATE_DO_NOT_COMMIT.md` — this list.
- `SPEC-PRIVATE.md` — the full specification, rationale, history, and evidence discussion.
- `SPEC_REVIEW.md` — internal specification review.
- `design/` — the complete directory, including all prose and Julia scripts.
- `test/validation.jl` — checks for the private statistical feed runners.
- `design/HANDOFF.md` — implementation handoff.
- `design/search/cycles.md` — retained local working notes.
- `design/search/fpga-2026-09-26.md` — local FPGA notes.

## Private working material

- `.worktrees/` — local checkouts, analysis, original evidence snapshots, and backups.
- Git history bundles and restore-check repositories.
- Task records, editorial notes, session records, and local release guides.

The selected evidence archives are exceptions only after their contents have been
checked against this list. Keep their original private snapshots and omission records.

Review backup: `.worktrees/analysis/private-design-20260927/SPEC_REVIEW.md`.
Full-history backup: `.worktrees/analysis/release-history-20260927/`.

`SPEC.md` is the public instructional specification. Keep its algorithms, building blocks,
stream rules, mappings, bounds, and vectors. Keep justification and design history private.

Keep `.gitignore` public, with generated-file patterns only and no Markdown exclusions.
Keep every file under `design/` outside the package commit.
Keep the private feed checks outside the public package test suite.
Public evidence may contain raw reports, preregistered protocols, matrices, scripts,
logs, and hashes. Exclude copies of the private design prose and the full specification.
Frozen scripts already selected for evidence replay remain in the separate evidence assets.

The canonical checkout is `/Users/bcox/Code/JuliaOSS/TandemRNG.jl`.
It is on `prepare/purerngs-engine`, based on public `main`, with preparation committed locally.
Local `main` still matches `origin/main`. The private files listed above remain untracked.
The old private main is retained as `backup/private-main-20260927`.
Obsolete worktrees, including their uncommitted files, are archived with hashes under
`.worktrees/analysis/canonical-checkout-20260927/`.

Selected public evidence assets: `.worktrees/analysis/public-naming-20260927/assets/`.
The older `release-assets/` directory and all original archives are private and superseded.
Upload only the three selected archives, checksum sidecars, and combined checksum manifest.
Keep local inventory, verification, and draft release-note files private.

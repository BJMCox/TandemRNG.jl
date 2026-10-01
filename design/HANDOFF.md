# Current TandemRNG checkout

Updated 2026-09-27 during PureRNGs engine preparation. This file is private.

The canonical checkout is `/Users/bcox/Code/JuliaOSS/TandemRNG.jl`.
It is on `prepare/purerngs-engine`, based on public commit
`4e66bad4b5ef4c859df6c05d36faea499d238d9e`. Local `main` still matches `origin/main`.
The public history has two commits. The evidence tag points to parent
`e072681d76ecac3ffb6121c730b904c860eb13d6`.

All six obsolete worktrees were archived with complete file contents and hashes,
then removed. Their contents include uncommitted changes, logs, and environments.
Read `.worktrees/analysis/canonical-checkout-20260927/README.md` for restoration.
The old root handoff remains in `canonical-before.tar.gz`.
The old private main remains on `backup/private-main-20260927`.
Do not use the former `.worktrees/reduced-round-margin` path.

`PRIVATE_DO_NOT_COMMIT.md` lists private files. Preparation is committed locally as
`1fb08b0b3e5c73da3e3067d30ba1b0dcb469c721`. The user has not requested a push.
No public commit, push, or remote history rewrite occurred during this cleanup.
Current evidence assets remain in `.worktrees/analysis/public-naming-20260927/assets/`.
Full package CI and docs passed at the current public commit before this cleanup.
AMDGPU hardware validation remains deferred by the user.

The PureRNGs engine-interface refactor belongs to a separate PureRNGs implementer.
Its investigation is `/Users/bcox/Code/JuliaOSS/PureRNGs.jl/PRIVATE-tandem-engine-20260927/REPORT.md`.
Keep distribution algorithms in PureRNGs and Tandem adaptation in its existing bridge.
Use the canonical Tandem path in all new environments and instructions.

The current Tandem preparation reuses cached state for forward moves through one row
and changes bridge defaults to `threaded = false`. It leaves native defaults and stream
bits unchanged. Future engine hooks, mapped fills, and conformance checks wait for the
actual PureRNGs interface. Do not implement distribution algorithms in Tandem.

Read `/Users/bcox/Code/JuliaOSS/TandemRNG.jl/.worktrees/analysis/engine-preparation-20260927/`
for the plan, exact baseline, reproducible probe, source variants, and raw timings.
`RESULTS.md` records the passing final checks and measured tradeoffs. The final
helper takes eight native vectors by value, avoiding whole-state stack stores in
scalar callers. The within-group short-move cases improve by 4.0–7.9 times on
batserv01, and large fills stay within 0.5% of baseline. Per-type scalar timing
variation and the group-boundary overhead remain recorded without a blanket
claim of unchanged scalar speed.

The user explicitly asked to await their go-ahead before interface work. Do not
begin the Tandem adapter, mapped fills, or new interface hooks before that approval.

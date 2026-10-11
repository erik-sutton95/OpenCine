# Navigation evaluation rubric

These cases are a frozen pre-migration navigation benchmark. The `pre-migration` snapshot names preserve their original SHAs and expected paths; they do not describe public main or current shared-code ownership. Updating the registry's main baseline must not restamp historical evaluation results. Current behavior and ownership require source review at the deployed pins.

Held-out cases in [cases.json](cases.json) against frozen sources in
[snapshots.json](snapshots.json). Use them to evaluate routing; never use them to tune
`AGENTS.md`, `docs/ROUTING.md` or summaries.

Disclosure: the cases, `ROUTING.md` and the summaries were written by the same agent in the
same session (2026-10-01). Several cases touch paths the routing guide also names, so these
cases measure navigation from the atlas as written, not independent generalization. Add
cases written by someone else before drawing conclusions about the guide itself.

## Protocol

1. Reconstruct each snapshot with `git archive <sha>` into a temporary folder; never switch a
   shared checkout. Give the agent no Git history, no reference answers and no network.
2. Arm A (minimal): `AGENTS.md`, `docs/ROUTING.md`, `repos/*/SUMMARY.md` plus source search.
   Arm B (graph-assisted): the same plus the committed snapshot reports and the locally built
   graphs at the same SHAs. Vary nothing else.
3. Give only `request` and `mode`. Ask for: owner repository and ref, ranked paths or symbols,
   supporting tests, whether code should change, uncertainty, repositories searched, tool-call
   count and elapsed time.
4. Score each case on the five criteria below (0, 1 or 2 each; maximum 10). Record scores and
   raw answers in a results file next to this rubric, with the arm and model.

## Criteria

| Criterion | 2 | 1 | 0 |
|---|---|---|---|
| Correct owner | Names `expected.owner` and the right ref (branch versus main) | Right repository, wrong or unstated ref | Wrong repository, or edits a copy instead of the donor |
| Relevant source and tests | At least one of `expected.paths` in its top three and any listed test found | A listed path found but ranked low, or tests missed | None found |
| Evidence freshness | Cites the pinned SHA or ref it read | Reads current files without saying which revision | Treats a candidate branch as main, or main as having branch-only code |
| Unsupported certainty | States what it could not verify (hardware, runtime) | Hedges vaguely | Claims a fix, support or qualification without evidence |
| Unnecessary exploration | Reaches the owner in few calls and stops when the answer needs no code (`code_change: false`) | Some detours | Proposes an edit for a no-code question, or searches every repository without need |

Locating a file is not proof of a fix. For `code_change: false` cases the right answer is an
explanation with evidence, not a patch.

## Status

Cases and path checks exist; `tests/test_evals.py` verifies every expected path (and every
expected absence) at its pinned SHA when the checkouts are available. No arm has been run
yet: results are **not run**, not passed.

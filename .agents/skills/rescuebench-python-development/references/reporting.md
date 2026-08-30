# Review Reporting

Lead with three independent outcomes: requested implementation, focused
behavioral verification, and static review. An implementation may be complete
while the static review remains failed. Never collapse these outcomes into one
pass/fail claim or describe the full review as passed while an in-scope check
fails.

Keep checked, changed, and unverified evidence separate. Include:

- workspace root, selected repository root, repository kind (`outer` or
  `independent`), branch, HEAD, and dirty state;
- whether the requested implementation is complete, partial, or blocked;
- review action and exact Python scope;
- staged, unstaged, untracked, and committed status as applicable;
- Python, Ruff, and Pylint versions;
- Ruff lint and Ruff format-check results for the complete Python scope;
- the production-only Pylint scope, executed result, and number of test Python
  files skipped by policy;
- focused-test commands and results as behavioral evidence separate from static
  checks;
- each calibrated finding and its classification;
- for every unresolved failed finding, whether Codex continued, stopped, or
  paused for the user, and why;
- files actually modified by Codex in the current slice;
- the explicit review-config path and whether it is repository-native or the
  workspace fallback;
- confirmation that committed history and other repositories were not reviewed
  during an ordinary independent-repository pass;
- boundaries not reviewed or not runtime-verified.

If the scope is empty, say that checks were skipped. Do not substitute a full
audit. If a tool is missing or output is undecodable, report the exact boundary
instead of claiming success.

For a test-only scope, report `Pylint skipped: no production Python`; never call
that a Pylint pass. For mixed scope, a Pylint pass applies only to the listed
production Python files. Test Python remains subject to Ruff, formatting, and
diff checks, while whether it actually ran must be reported separately.

If calibration concludes that further metric-driven refactoring would make the
design worse, report the implementation outcome and the failed Pylint result
side by side. Do not rename the failure as a warning, exemption, or pass.

Never claim that success in one Git repository covers the outer workspace,
another repository under `repos/`, AutoDL, Unreal, model inference, or training.
Local static checks and plot smoke tests do not establish cloud or simulator
behavior.

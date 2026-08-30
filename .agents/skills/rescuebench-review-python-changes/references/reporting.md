# Review Reporting

Lead with the outcome and keep checked, changed, and unverified evidence
separate. Include:

- repository root, branch, HEAD, and dirty state;
- review action and exact Python scope;
- staged, unstaged, untracked, and committed status as applicable;
- Python, Ruff, and Pylint versions;
- Ruff lint, Ruff format-check, Pylint, and focused-test results;
- each calibrated finding and its classification;
- files actually modified by Codex in the current slice;
- boundaries not reviewed or not runtime-verified.

If the scope is empty, say that checks were skipped. Do not substitute a full
audit. If a tool is missing or output is undecodable, report the exact boundary
instead of claiming success.

Never claim that outer-workspace success covers `repos/RescueBench`, AutoDL,
Unreal, model inference, or training. Local static checks and plot smoke tests do
not establish cloud or simulator behavior.

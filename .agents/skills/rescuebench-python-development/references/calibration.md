# Lint Calibration

Use this reference for a new rule, a changed threshold, a changed
`pyproject.toml`, or a user request to evaluate whether a finding reflects code
design or parameter design.

Before editing code or policy, report for every relevant finding:

- message code, rule name, file, and line;
- measured count and configured limit when the tool provides them;
- the amount beyond the limit;
- whether findings cluster in one responsibility-heavy unit or occur broadly;
- whether the code is production, test, generated, or framework-shaped;
- whether responsibilities can be separated without artificial indirection;
- one classification: `parameter-design`, `code-design`, or `inconclusive`.

The helper classifies paths under `test/` or `tests/`, `test_*.py`, `*_test.py`,
and `conftest.py` as test Python. These files are excluded from Pylint by policy.
Do not calibrate or repair Pylint findings for them, and do not add inline
disables or raise global limits on their behalf. Ruff, formatting, diff checks,
and explicit focused test execution remain applicable.

If a production module is accidentally classified as test Python because of
its path or filename, treat that as a repository-role or naming issue. Do not
parse mixed Pylint output or inspect class names to override the path policy.

Use `parameter-design` only when a rule measures the project poorly or would
force fragmentation of cohesive code. Use `code-design` when excess size,
branching, arguments, or coupling exposes a natural responsibility boundary.
Use `inconclusive` when both explanations remain plausible.

A static target version that conflicts with the selected code's authoritative
runtime requirement is `parameter-design`. Correct or explicitly override the
review target before changing production structure in response to findings or
automatic fixes produced for the wrong version.

Classification controls the next repair decision, not the tool result. A failed
Pylint run remains failed regardless of classification:

- `code-design`: Codex may refactor along a natural responsibility boundary when
  the benefit is proportionate and the work remains in scope. Passing the metric
  is not by itself a requirement.
- `parameter-design`: stop metric-driven restructuring, preserve the cohesive
  design, and report the unresolved Pylint failure.
- `inconclusive`: pause before structural or policy changes, report the
  unresolved failure, and let the user decide.

Do not tune a limit to the largest observed value. One file is not enough to
calibrate a global threshold. Do not add wrappers, parameter bundles, helper
layers, or exemptions solely to reduce a metric. Wait for the user's decision
before changing a threshold, disabling a rule, adding an inline exemption, or
refactoring an inconclusive case.

For `scripts/plot_nomad_xy_trajectory.py`, treat data loading/validation and plot
assembly as candidate boundaries, not a predetermined split. A line-count or
argument-count finding alone does not establish that either function must be
refactored.

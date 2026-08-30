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

Use `parameter-design` only when a rule measures the project poorly or would
force fragmentation of cohesive code. Use `code-design` when excess size,
branching, arguments, or coupling exposes a natural responsibility boundary.
Use `inconclusive` when both explanations remain plausible.

Do not tune a limit to the largest observed value. One file is not enough to
calibrate a global threshold. Do not add wrappers, parameter bundles, helper
layers, or exemptions solely to reduce a metric. Wait for the user's decision
before changing a threshold, disabling a rule, adding an inline exemption, or
refactoring an inconclusive case.

For `scripts/plot_nomad_xy_trajectory.py`, treat data loading/validation and plot
assembly as candidate boundaries, not a predetermined split. A line-count or
argument-count finding alone does not establish that either function must be
refactored.

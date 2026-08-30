---
name: rescuebench-review-python-changes
description: Review and incrementally improve changed Python files in the outer RescueBench workspace on Windows. Use for changed-file inspection, Ruff and Pylint checks, lint calibration, focused refactoring, or committed-diff verification. Never enter independent repositories under repos/ unless the user explicitly requests a separate repository review.
---

# RescueBench Python Change Review

Operate on the outer workspace rooted at:

```text
D:\Workspace\00_MyRepo\Rescubench
```

The repositories under `repos/` are independently managed and are outside this
skill. Never inspect, lint, format, or modify them through this workflow. A
separate repository request requires its own checkout and worktree validation.

## Resolve the helper

Resolve the helper relative to this loaded `SKILL.md`; do not search for it or
resolve it from the current directory:

```powershell
$skillFilePath = '<loaded-SKILL.md-absolute-path>'
$helperPath = [System.IO.Path]::GetFullPath(
    (Join-Path (Split-Path -Parent $skillFilePath) `
        'scripts\Invoke-RescueBenchPythonReview.ps1')
)
```

Use the current worktree root explicitly with every action.

## Route by user intent

- For analysis, inspection, or review-only requests, use `Probe`, `Scope`, and
  `CheckChanged`. These actions are read-only.
- Use `FixExplicit` only when the user has authorized source changes in the
  current request. Pass only files actually selected for that one repair slice.
- Use `VerifyCommitted` only with a user-supplied base revision.
- Use `FullWorkspaceAudit` only when the user explicitly requests a full audit
  of the outer workspace and pass `-FullAuditAuthorized`.
- If the request targets `repos/`, stop this workflow and explain the independent
  repository boundary.

Start ordinary reviews with:

```powershell
$repositoryPath = 'D:\Workspace\00_MyRepo\Rescubench'
& $helperPath -RepositoryPath $repositoryPath -Action Probe
& $helperPath -RepositoryPath $repositoryPath -Action Scope
& $helperPath -RepositoryPath $repositoryPath -Action CheckChanged
```

`Scope` is authoritative. It includes Python files changed relative to `HEAD`
plus untracked, non-ignored Python files, excludes deletions, and reports staged,
unstaged, and untracked state separately. Never replace an empty scope with a
directory, wildcard, recursive filesystem search, or full audit.

## Plan decision-changing work once

Read [references/execution-strategy.md](references/execution-strategy.md) before
an authorized change that introduces a tool or dependency, changes multiple
tightly coupled files, or alters entrypoints or import boundaries. Skip it for
review-only work and ordinary single-finding repairs.

- Verify only unknowns that could change the implementation route. Reuse facts
  already established for the unchanged checkout and Conda environment.
- Treat `environment.windows.yml` as the test-tool source of truth. In ordinary
  reviews, invoke targeted pytest directly in `rescuebench-local`; do not run a
  separate pytest presence or version probe. Re-diagnose only after an
  environment or manifest change, an environment switch, or an actual command
  failure.
- Define the supported entrypoints, import boundaries, and focused behavioral
  checks before editing, then keep one tightly coupled change in one repair
  slice. Do not invoke the complete review helper after every file edit.

## Calibrate before changing policy

Read [references/calibration.md](references/calibration.md) when a new rule or
threshold fails, `pyproject.toml` changes, or the user asks whether a finding is
bad code or a bad limit. Report the evidence before changing code or policy.

Never change thresholds, disable rules, add inline exemptions, or introduce
`noqa` merely to pass the review. Do not use `--unsafe-fixes`.

## Repair one slice at a time

For an authorized repair:

1. Select one finding or one tightly coupled group.
2. State the selected files and responsibility boundary.
3. Preserve unrelated staged, unstaged, and untracked changes.
4. Complete the authorized slice and run cheap, focused checks while it is still
   changing.
5. Invoke `FixExplicit` once with every explicit Git-relative Python path in the
   completed slice.
6. Run focused behavioral tests against the resulting files when they exist.

`FixExplicit` already runs the complete changed-Python Ruff, format-check,
Pylint, and diff review after formatting. Do not immediately invoke a duplicate
`CheckChanged`. Run `CheckChanged` again only if files or relevant worktree state
change afterward without another `FixExplicit` run.

Example:

```powershell
& $helperPath `
    -RepositoryPath $repositoryPath `
    -Action FixExplicit `
    -PythonFile @('scripts/example.py')
```

Ruff may modify only the explicit files. Pylint and read-only Ruff checks always
cover the complete selected scope so cross-file findings remain visible.

## Verification modes

Verify committed Python changes without guessing a base revision:

```powershell
& $helperPath `
    -RepositoryPath $repositoryPath `
    -Action VerifyCommitted `
    -BaseRevision '<explicit-commit>'
```

Run a full outer-workspace audit only with explicit authorization:

```powershell
& $helperPath `
    -RepositoryPath $repositoryPath `
    -Action FullWorkspaceAudit `
    -FullAuditAuthorized
```

Full-audit findings are a separate report and are not a completion condition for
ordinary changed-file work.

## Preserve review integrity

- Never pass a directory, wildcard, `.`, or a path under `repos/` to
  `FixExplicit`.
- Never stage, commit, reset, clean, stash, discard, or rewrite user changes.
- Do not claim that a read-only check modified or fixed a file.
- Do not claim coverage of `repos/`, AutoDL, Unreal runtime, or model execution.
- Stop on undecodable output or garbled paths and report the encoding boundary.
- Use the `rescuebench-local` Conda environment with Windows UTF-8 settings.
- Read [references/reporting.md](references/reporting.md) before presenting the
  final review result.

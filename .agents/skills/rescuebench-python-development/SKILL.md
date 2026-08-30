---
name: rescuebench-python-development
description: >-
  Develop, review, and incrementally validate current-worktree Python changes
  in RescueBench or an explicitly targeted independent repository under repos/.
  Use whenever authorized work creates or modifies Python, including fixes and
  refactors; skip read-only explanation unless worktree inspection is requested.
---

# RescueBench Python Development

The workspace is rooted at:

```text
D:\Workspace\00_MyRepo\Rescubench
```

The outer repository ignores `/repos/`. A directory such as
`repos/RescueBench` is not a submodule or part of the outer Git tree; it is an
independent Git repository stored under the workspace. Never use outer
`git status` to infer its state.

When the user explicitly targets code under `repos/`, enter the corresponding
independent Git repository directly and apply the same changed-file review
principles there. Do not recursively discover or combine repositories.

## Select exactly one repository

Before inspection or editing, resolve the repository from the named target:

1. For an outer-workspace target, select the outer root.
2. For a target under `repos/`, run Git from the target path or its parent and
   resolve `git rev-parse --show-toplevel`.
3. Verify that the resolved root is under the workspace `repos/` directory and
   has a Git common directory distinct from the outer repository.
4. Report the selected root, branch, HEAD, and dirty state before editing.

One helper invocation may cover only one Git repository. If a request spans the
outer repository and an independent repository, run separate review passes and
report them separately.

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
- For an authorized task that creates or modifies Python, use this workflow as
  part of the same development task. Complete one cohesive, stable change slice,
  run its focused behavioral checks, and invoke `FixExplicit` before reporting
  the slice's implementation and review outcomes.
- Use `FixExplicit` only when the user has authorized source changes in the
  current request. Pass only files actually selected for that one repair slice.
- Use `VerifyCommitted` only for the outer repository and with a user-supplied
  base revision.
- Use `FullWorkspaceAudit` only when the user explicitly requests a full audit
  of the outer workspace and pass `-FullAuditAuthorized`.
- Independent repositories allow only `Probe`, `Scope`, `CheckChanged`, and
  `FixExplicit`. Never verify their committed history or run a full audit.

Start ordinary reviews with:

```powershell
$repositoryPath = 'D:\Workspace\00_MyRepo\Rescubench'
& $helperPath -RepositoryPath $repositoryPath -Action Probe
& $helperPath -RepositoryPath $repositoryPath -Action Scope
& $helperPath -RepositoryPath $repositoryPath -Action CheckChanged
```

For an explicitly targeted independent repository, pass its exact Git root:

```powershell
$repositoryPath = 'D:\Workspace\00_MyRepo\Rescubench\repos\RescueBench'
& $helperPath -RepositoryPath $repositoryPath -Action Probe
& $helperPath -RepositoryPath $repositoryPath -Action Scope
& $helperPath -RepositoryPath $repositoryPath -Action CheckChanged
```

`Scope` is authoritative. It includes Python files changed relative to `HEAD`
plus untracked, non-ignored Python files, excludes deletions, and reports staged,
unstaged, and untracked state separately. Never replace an empty scope with a
directory, wildcard, recursive filesystem search, or full audit.

`HEAD` is the boundary, not `origin/main`. Ordinary reviews therefore ignore
all committed files whether or not the commits have been pushed.

## Apply tools by code role

Classify repository-relative Python paths as test code when they are under a
`test/` or `tests/` directory, are named `test_*.py` or `*_test.py`, or are
named `conftest.py`. Classification is path-based; do not inspect class names or
source content to guess whether a file is a test.

- Ruff lint, Ruff format-check, Git diff checks, and untracked whitespace checks
  cover the complete selected Python scope.
- Pylint covers only the production-Python subset. Never invoke Pylint for test
  Python and never parse or suppress its output after checking mixed scope.
- A test-only scope may pass with Pylint explicitly skipped. Report that skip;
  do not describe it as a Pylint pass.
- Focused test execution is separate behavioral evidence. Static success does
  not establish that a test ran or that production behavior is correct.

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

Test Python is excluded from Pylint by review policy, not by per-message
exemptions. Do not split, wrap, or otherwise refactor a test merely to satisfy a
Pylint size, complexity, documentation, naming, or design finding.

## Interpret strict results without forcing refactors

Tool results are authoritative: a nonzero Pylint result remains a failed Pylint
result until a later run actually passes. The failure is development feedback,
not an unconditional command to keep refactoring until every metric passes.

For a structural or threshold finding, read
[references/calibration.md](references/calibration.md) and let its classification
control the next action:

- `code-design`: Codex may continue along a natural responsibility boundary
  when the benefit is proportionate and remains within the authorized task.
- `parameter-design`: stop metric-driven restructuring, preserve the cohesive
  design, and report the unresolved tool failure.
- `inconclusive`: stop before structural or policy changes and ask the user to
  choose; report the unresolved tool failure meanwhile.

Do not add empty wrappers, parameter objects, helper layers, or artificial file
fragments merely to obtain a passing number. A requested implementation may be
complete while the full static review remains failed. Report those outcomes
separately and never call the full review passed while an in-scope check fails.

## Develop or repair one slice at a time

For authorized development or repair:

1. Select one finding or one tightly coupled group.
2. State the selected files and responsibility boundary.
3. Preserve unrelated staged, unstaged, and untracked changes.
4. Complete the authorized slice and run cheap, focused checks while it is still
   changing.
5. Invoke `FixExplicit` once with every explicit Git-relative Python path in the
   completed slice.
6. Run focused behavioral tests against the resulting files when they exist.

`FixExplicit` already runs complete-scope Ruff, format-check, and diff review,
plus production-only Pylint, after formatting. Do not immediately invoke a
duplicate `CheckChanged`. Run `CheckChanged` again only if files or relevant
worktree state change afterward without another `FixExplicit` run.

Example:

```powershell
& $helperPath `
    -RepositoryPath $repositoryPath `
    -Action FixExplicit `
    -PythonFile @('scripts/example.py')
```

Ruff may modify only the explicit files. Read-only Ruff checks cover the complete
selected scope so cross-file findings remain visible; Pylint covers only the
production-Python subset.

## Verification modes

Verify outer-repository committed Python changes without guessing a base
revision:

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
ordinary changed-file work. A full audit discovers all Python files for
complete-scope checks but still excludes test Python from Pylint.

## Preserve review integrity

- Never pass a directory, wildcard, `.`, or a path outside the selected Git
  repository to `FixExplicit`.
- In an independent repository, `FixExplicit` may touch only explicit files in
  that repository's current changed-Python scope.
- Never stage, commit, reset, clean, stash, discard, or rewrite user changes.
- Do not claim that a read-only check modified or fixed a file.
- Do not claim that one repository's result covers another repository, AutoDL,
  Unreal runtime, or model execution.
- Do not claim that test Python passed Pylint; report that it was skipped by
  policy and report focused test execution separately.
- Stop on undecodable output or garbled paths and report the encoding boundary.
- Use the `rescuebench-local` Conda environment with Windows UTF-8 settings.
- Read [references/reporting.md](references/reporting.md) before presenting the
  final review result.

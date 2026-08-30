# Execution Strategy for Structural Repairs

Read this reference only for an authorized change that introduces a tool or
dependency, changes multiple tightly coupled files, or alters entrypoints or
import boundaries. Ordinary review-only work and single-finding repairs should
use the main workflow directly.

## Objective

Resolve route-changing uncertainty cheaply, define the observable acceptance
paths, complete one cohesive repair slice, and pay for the full review gate once
the slice is stable.

This is not a request for broad discovery. A probe is useful only when its
answer could change the implementation.

## Resolve route-changing uncertainty

Before editing, identify the smallest unanswered questions that select between
materially different implementations. Typical examples are:

- which Conda environment owns the command;
- whether an undeclared tool or dependency is actually available;
- whether direct-script execution, module execution, or both are supported;
- whether a data-only import must avoid optional plotting or runtime imports;
- which explicit focused test command proves the requested behavior.

Reuse current-turn evidence while the checkout, manifest, and environment are
unchanged. Do not add a second presence check before a command whose direct
execution already gives a precise answer.

For this workspace, `environment.windows.yml` declares pytest. Run targeted
tests directly through:

```powershell
conda run -n rescuebench-local --no-capture-output `
    python -m pytest <explicit-test-path>
```

Do not separately call `find_spec`, `pip show`, or `pytest --version` during an
ordinary review. Re-diagnose pytest only when the environment or manifest has
changed, a different environment is selected, or the pytest command fails.

## Define the acceptance paths

Write down only the paths that the change must preserve or introduce. For a
structural script repair, the useful matrix may include:

| Boundary | Focused evidence |
| --- | --- |
| Existing CLI entrypoint | Run its `--help` or a minimal explicit invocation |
| Module entrypoint | Run `python -m <module> --help` when it is supported |
| Import boundary | Import the lower-level module and inspect required side effects |
| Data contract | Exercise one valid and one invalid fixture |
| Resource lifecycle | Force the relevant failure path and verify cleanup |

Do not invent compatibility paths that the current code, documentation, or user
request does not require.

## Choose one cohesive repair slice

Files belong in one slice when they must change together to produce one usable
outcome, such as a data module, its plotting consumer, the existing CLI, and
their focused tests. Do not split such a change into one slice per file merely
because the review helper accepts explicit paths.

Keep unrelated findings in later slices. If a newly discovered issue changes
the planned responsibility boundary, stop and revise the slice once instead of
adding repeated local workarounds.

## Use a feedback ladder

Use checks in increasing order of cost:

1. Run the cheapest import, CLI, or small behavioral check that can reject the
   current implementation route.
2. Run the explicit focused pytest target for the completed behavior.
3. Invoke `FixExplicit` once for all Python files in the stable slice. It runs
   Ruff on the complete changed-Python scope and Pylint only on production
   Python.
4. Re-run a focused test only when `FixExplicit` changed relevant source or when
   the final behavior has not yet been exercised.

`FixExplicit` performs safe Ruff fixes and formatting for the explicit files,
then runs complete-scope Ruff and diff checks plus production-only Pylint. Test
Python does not enter Pylint, but its focused execution remains separate
behavioral evidence. Do not follow `FixExplicit` immediately with an identical
`CheckChanged`. A later `CheckChanged` is warranted only after subsequent edits
or an external worktree-state change.

## Avoid these failure patterns

- choosing a test framework before checking the project manifest;
- discovering supported entrypoints one at a time after the refactor;
- using full changed-scope review as the inner edit loop;
- probing a known-stable tool before every ordinary test run;
- changing lint thresholds or adding wrappers only to erase a calibrated
  metric;
- restructuring test Python only to satisfy a Pylint finding that is outside
  the test-code policy;
- turning one past failure into a universal preflight checklist.

"""Focused tests for loading and plotting a NoMaD XY trajectory."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts.trajectory_plot import nomad_xy_plot
from scripts.trajectory_plot.nomad_xy_data import (
    XYTrajectoryPlotData,
    load_xy_trajectory_data,
)


def _write_jsonl(path: Path, records: list[dict[str, object]]) -> None:
    """Write records in the JSONL format consumed by the loader."""

    content = "".join(f"{json.dumps(record)}\n" for record in records)
    path.write_text(content, encoding="utf-8")


def _task_records() -> list[dict[str, object]]:
    """Return enough task records for point_id=7 index selection."""

    return [
        {
            "level": 0,
            "env_id": f"env-{point_id}",
            "agent_loc": [0, 0, 0],
            "injured_player_loc": [100, 0, 0],
            "stretcher_loc": [100, 100, 0],
            "ambulance_loc": [200, 100, 0],
        }
        for point_id in range(8)
    ]


def _trajectory_record() -> dict[str, object]:
    """Return one episode with a reset-cache point followed by two valid poses."""

    return {
        "level": 0,
        "point_id": 7,
        "episode_id": 0,
        "trajectory": [
            [900, 900, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0],
            [100, 100, 0, 0, 0, 0],
        ],
    }


def _benchmark_record(*, steps: int = 2) -> dict[str, object]:
    """Return the benchmark half of the selected episode."""

    return {
        "level": 0,
        "point_id": 7,
        "episode_id": 0,
        "steps": steps,
        "time_cost": 1.5,
        "phase1_success": True,
        "phase1_steps": 1,
        "failure_reason": None,
    }


def _load_fixture(
    tmp_path: Path,
    *,
    trajectory_records: list[dict[str, object]] | None = None,
    benchmark_record: dict[str, object] | None = None,
) -> XYTrajectoryPlotData:
    """Write a compact three-file fixture and load the selected episode."""

    trajectory_path = tmp_path / "trajectory.jsonl"
    benchmark_path = tmp_path / "benchmark.jsonl"
    task_path = tmp_path / "tasks.jsonl"
    _write_jsonl(
        trajectory_path,
        trajectory_records or [_trajectory_record()],
    )
    _write_jsonl(benchmark_path, [benchmark_record or _benchmark_record()])
    _write_jsonl(task_path, _task_records())

    return load_xy_trajectory_data(
        trajectory_jsonl_path=trajectory_path,
        benchmark_jsonl_path=benchmark_path,
        task_jsonl_path=task_path,
        level=0,
        point_id=7,
        episode_id=0,
        trajectory_start_index=1,
    )


def test_load_joins_episode_and_preserves_raw_step_numbers(tmp_path: Path) -> None:
    """The three files should join while retained poses keep raw indices."""

    plot_data = _load_fixture(tmp_path)

    assert plot_data.env_id == "env-7"
    assert plot_data.steps == (1, 2)
    assert plot_data.trajectory_xy_cm == ((0.0, 0.0), (100.0, 100.0))
    assert plot_data.phase1_end_step == 1
    assert plot_data.agent_xy_cm == (0.0, 0.0)


def test_load_rejects_duplicate_episode_records(tmp_path: Path) -> None:
    """An episode key must select exactly one trajectory record."""

    duplicate = _trajectory_record()
    with pytest.raises(ValueError, match="Duplicate trajectory records"):
        _load_fixture(tmp_path, trajectory_records=[duplicate, duplicate.copy()])


def test_load_rejects_benchmark_step_mismatch(tmp_path: Path) -> None:
    """Benchmark steps must agree with an N+1 environment trajectory."""

    with pytest.raises(ValueError, match="expected steps=2"):
        _load_fixture(tmp_path, benchmark_record=_benchmark_record(steps=3))


def test_plot_writes_png(tmp_path: Path) -> None:
    """Validated data should render to a non-empty PNG file."""

    output_path = nomad_xy_plot.plot_xy_topdown(
        _load_fixture(tmp_path),
        tmp_path / "trajectory.png",
    )

    assert output_path.is_file()
    assert output_path.stat().st_size > 0


def test_plot_closes_figure_when_save_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The plotter should close its figure even when image writing fails."""

    closed_figures: list[object] = []

    def _raise_save_error(*_args: object, **_kwargs: object) -> None:
        raise OSError("save failed")

    monkeypatch.setattr("matplotlib.figure.Figure.savefig", _raise_save_error)
    monkeypatch.setattr(nomad_xy_plot.plt, "close", closed_figures.append)

    with pytest.raises(OSError, match="save failed"):
        nomad_xy_plot.plot_xy_topdown(
            _load_fixture(tmp_path),
            tmp_path / "unwritable.png",
        )

    assert len(closed_figures) == 1

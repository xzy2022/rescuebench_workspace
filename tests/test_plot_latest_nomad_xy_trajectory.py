"""Tests for resolving the latest NoMaD logs and rendering their XY plot."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from scripts import plot_latest_nomad_xy_trajectory as latest_plot


def _write_jsonl(path: Path, records: list[dict[str, object]]) -> None:
    """Write JSON objects to a UTF-8 JSONL file."""

    path.parent.mkdir(parents=True, exist_ok=True)
    content = "".join(f"{json.dumps(record)}\n" for record in records)
    path.write_text(content, encoding="utf-8")


def _trajectory_record() -> dict[str, object]:
    """Return a selected episode with one reset-cache pose."""

    record = _episode_key()
    record["trajectory"] = [
        [900, 900, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0],
        [100, 100, 0, 0, 0, 0],
    ]
    return record


def _benchmark_record() -> dict[str, object]:
    """Return benchmark data matching the N+1 trajectory fixture."""

    record = _episode_key()
    record.update(
        {
            "steps": 2,
            "time_cost": 1.5,
            "phase1_success": True,
            "phase1_steps": 1,
            "failure_reason": None,
        }
    )
    return record


def _episode_key() -> dict[str, object]:
    """Return the common identity of the fixture episode."""

    return {
        "level": 0,
        "point_id": 7,
        "episode_id": 0,
    }


def _write_log_pair(directory: Path, timestamp: str) -> tuple[Path, Path]:
    """Write a complete same-timestamp trajectory and benchmark pair."""

    trajectory_path = directory / f"trajectories_nomad_{timestamp}.jsonl"
    benchmark_path = directory / f"benchmark_nomad_{timestamp}.jsonl"
    _write_jsonl(trajectory_path, [_trajectory_record()])
    _write_jsonl(benchmark_path, [_benchmark_record()])
    return trajectory_path, benchmark_path


def _write_task_file(task_directory: Path) -> Path:
    """Write enough level-zero task rows to select point_id=7."""

    task_path = task_directory / "level_0.jsonl"
    records = [_task_record(point_id) for point_id in range(8)]
    _write_jsonl(task_path, records)
    return task_path


def _task_record(point_id: int) -> dict[str, object]:
    """Build one level-zero task row for a given positional point ID."""

    locations = {
        "agent_loc": [0, 0, 0],
        "injured_player_loc": [100, 0, 0],
        "stretcher_loc": [100, 100, 0],
        "ambulance_loc": [200, 100, 0],
    }
    return {"level": 0, "env_id": f"env-{point_id}", **locations}


def test_resolve_selects_latest_complete_pair_and_ignores_newer_orphan(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Selection should use filename time and require a complete pair."""

    task_directory = tmp_path / "tasks"
    task_path = _write_task_file(task_directory)
    monkeypatch.setattr(latest_plot, "_TASK_JSONL_DIRECTORY", task_directory)
    log_root = tmp_path / "run"
    _write_log_pair(log_root / "nomad", "20260830_100000")
    expected_trajectory, expected_benchmark = _write_log_pair(
        log_root / "nomad",
        "20260830_120000",
    )
    _write_jsonl(
        log_root / "nomad" / "trajectories_nomad_20260830_130000.jsonl",
        [_trajectory_record()],
    )

    inputs = latest_plot.resolve_latest_nomad_inputs(log_root, level=0)

    assert inputs.trajectory_jsonl == expected_trajectory.resolve()
    assert inputs.benchmark_jsonl == expected_benchmark.resolve()
    assert inputs.task_jsonl == task_path.resolve()
    assert inputs.timestamp == "20260830_120000"


def test_resolve_rejects_duplicate_latest_pairs(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Two directories with the same latest timestamp are ambiguous."""

    task_directory = tmp_path / "tasks"
    _write_task_file(task_directory)
    monkeypatch.setattr(latest_plot, "_TASK_JSONL_DIRECTORY", task_directory)
    log_root = tmp_path / "run"
    _write_log_pair(log_root / "first", "20260830_120000")
    _write_log_pair(log_root / "second", "20260830_120000")

    with pytest.raises(ValueError, match="Multiple complete NoMaD log pairs"):
        latest_plot.resolve_latest_nomad_inputs(log_root, level=0)


def test_parse_args_uses_documented_defaults(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Only the log path should be required by the CLI."""

    monkeypatch.setattr(
        sys,
        "argv",
        ["plot_latest_nomad_xy_trajectory.py", "--log-path", str(tmp_path)],
    )

    args = latest_plot.parse_args()

    assert args.level == 0
    assert args.point_id == 1
    assert args.episode_id == 0
    assert args.trajectory_start_index == 0
    assert args.output is None


def test_main_honors_explicit_output_and_writes_png(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An explicit output path should override the generated filename."""

    task_directory = tmp_path / "tasks"
    _write_task_file(task_directory)
    monkeypatch.setattr(latest_plot, "_TASK_JSONL_DIRECTORY", task_directory)
    log_root = tmp_path / "run"
    _write_log_pair(log_root / "nomad", "20260830_120000")
    output_path = tmp_path / "custom" / "chosen.png"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "plot_latest_nomad_xy_trajectory.py",
            "--log-path",
            str(log_root),
            "--point-id",
            "7",
            "--trajectory-start-index",
            "1",
            "--output",
            str(output_path),
        ],
    )

    assert latest_plot.main() == 0
    assert output_path.is_file()
    assert output_path.stat().st_size > 0


def test_default_output_contains_log_timestamp_and_episode(
    tmp_path: Path,
) -> None:
    """The fallback output should be unique to the pair and episode."""

    pair_directory = tmp_path / "nomad"
    trajectory_path, benchmark_path = _write_log_pair(
        pair_directory,
        "20260830_120000",
    )
    inputs = latest_plot.NoMaDInputPaths(
        trajectory_jsonl=trajectory_path,
        benchmark_jsonl=benchmark_path,
        task_jsonl=tmp_path / "level_0.jsonl",
        timestamp="20260830_120000",
    )
    selection = latest_plot.EpisodeSelection(level=0, point_id=7, episode_id=2)

    output_path = latest_plot.resolve_output_path(None, inputs, selection)

    assert output_path == pair_directory / (
        "trajectory_xy_topdown_nomad_20260830_120000_L0_P7_E2.png"
    )

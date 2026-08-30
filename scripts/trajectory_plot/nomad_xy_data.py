"""Load and validate data for a top-down RescueBench XY trajectory plot."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class XYTrajectoryPlotData:
    """Validated, file-independent inputs for the XY trajectory plot."""

    level: int
    point_id: int
    episode_id: int
    env_id: str
    trajectory_start_index: int
    steps: tuple[int, ...]
    trajectory_xy_cm: tuple[tuple[float, float], ...]
    phase1_end_step: int | None
    agent_xy_cm: tuple[float, float]
    injured_xy_cm: tuple[float, float]
    stretcher_xy_cm: tuple[float, float]
    ambulance_xy_cm: tuple[float, float]
    steps_total: int
    time_cost: float
    failure_reason: str


@dataclass(frozen=True)
class _EpisodeRecords:
    """The three source records joined for one selected episode."""

    trajectory: dict[str, Any]
    benchmark: dict[str, Any]
    task: dict[str, Any]


def _resolve_input_file(path_value: str | Path, label: str) -> Path:
    path = Path(path_value).expanduser().resolve()
    if not path.is_file():
        raise FileNotFoundError(f"{label} does not exist or is not a file: {path}")
    return path


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, start=1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError(f"{path}:{line_number} is not a JSON object")
            records.append(record)
    if not records:
        raise ValueError(f"No non-empty JSON records found in {path}")
    return records


def _select_episode_record(
    records: list[dict[str, Any]],
    *,
    level: int,
    point_id: int,
    episode_id: int,
    label: str,
) -> dict[str, Any]:
    key = (level, point_id, episode_id)
    selected = [
        record
        for record in records
        if (
            record.get("level"),
            record.get("point_id"),
            record.get("episode_id"),
        )
        == key
    ]
    if len(selected) == 1:
        return selected[0]
    if not selected:
        raise ValueError(f"No {label} record matches episode key {key}")
    raise ValueError(f"Duplicate {label} records match episode key {key}")


def _load_task_record(
    task_jsonl_path: Path,
    level: int,
    point_id: int,
) -> dict[str, Any]:
    records = _load_jsonl(task_jsonl_path)
    if not 0 <= point_id < len(records):
        raise IndexError(
            f"point_id={point_id} is outside {task_jsonl_path} "
            f"(non-empty records={len(records)})"
        )
    task = records[point_id]
    declared_level = task.get("level")
    if declared_level != level:
        raise ValueError(
            f"Task record index {point_id} declares level={declared_level}, "
            f"but level={level} was requested"
        )
    return task


def _read_xy(record: dict[str, Any], field: str) -> tuple[float, float]:
    pose = record.get(field)
    if not isinstance(pose, (list, tuple)) or len(pose) < 2:
        raise ValueError(f"Task field {field!r} must contain at least [x, y]")
    x, y = float(pose[0]), float(pose[1])
    if not math.isfinite(x) or not math.isfinite(y):
        raise ValueError(f"Task field {field!r} contains a non-finite XY value")
    return x, y


def _read_trajectory_xy(
    record: dict[str, Any],
) -> tuple[tuple[float, float], ...]:
    raw_trajectory = record.get("trajectory")
    if not isinstance(raw_trajectory, list):
        raise ValueError("Trajectory record must contain a trajectory list")

    trajectory_xy: list[tuple[float, float]] = []
    for index, pose in enumerate(raw_trajectory):
        if not isinstance(pose, (list, tuple)) or len(pose) < 6:
            raise ValueError(
                f"trajectory[{index}] must contain [x, y, z, roll, yaw, pitch]"
            )
        x, y = float(pose[0]), float(pose[1])
        if not math.isfinite(x) or not math.isfinite(y):
            raise ValueError(f"trajectory[{index}] contains a non-finite XY value")
        trajectory_xy.append((x, y))
    return tuple(trajectory_xy)


def _read_nonnegative_int(record: dict[str, Any], field: str) -> int:
    value = record.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"Benchmark field {field!r} must be a non-negative integer")
    return value


def _read_nonnegative_float(record: dict[str, Any], field: str) -> float:
    raw_value = record.get(field)
    if isinstance(raw_value, bool) or not isinstance(raw_value, (int, float)):
        raise ValueError(
            f"Benchmark field {field!r} must be a finite non-negative number"
        )
    value = float(raw_value)
    if not math.isfinite(value) or value < 0:
        raise ValueError(
            f"Benchmark field {field!r} must be a finite non-negative number"
        )
    return value


def _validate_selection(
    level: int,
    point_id: int,
    episode_id: int,
    trajectory_start_index: int,
) -> tuple[int, int, int]:
    episode_key = (level, point_id, episode_id)
    if any(
        isinstance(value, bool) or not isinstance(value, int) or value < 0
        for value in episode_key
    ):
        raise ValueError(
            "level, point_id, and episode_id must be non-negative integers"
        )
    if isinstance(trajectory_start_index, bool) or not isinstance(
        trajectory_start_index, int
    ):
        raise ValueError("trajectory_start_index must be an integer")
    return episode_key


def _load_episode_records(
    trajectory_path: Path,
    benchmark_path: Path,
    task_path: Path,
    episode_key: tuple[int, int, int],
) -> _EpisodeRecords:
    level, point_id, episode_id = episode_key
    return _EpisodeRecords(
        trajectory=_select_episode_record(
            _load_jsonl(trajectory_path),
            level=level,
            point_id=point_id,
            episode_id=episode_id,
            label="trajectory",
        ),
        benchmark=_select_episode_record(
            _load_jsonl(benchmark_path),
            level=level,
            point_id=point_id,
            episode_id=episode_id,
            label="benchmark",
        ),
        task=_load_task_record(task_path, level, point_id),
    )


def _prepare_trajectory(
    trajectory_record: dict[str, Any],
    benchmark_record: dict[str, Any],
    trajectory_start_index: int,
) -> tuple[tuple[tuple[float, float], ...], tuple[int, ...], int]:
    raw_trajectory_xy = _read_trajectory_xy(trajectory_record)
    if not 0 <= trajectory_start_index < len(raw_trajectory_xy):
        raise IndexError(
            f"trajectory_start_index={trajectory_start_index} is outside the raw "
            f"trajectory (points={len(raw_trajectory_xy)})"
        )

    trajectory_xy = raw_trajectory_xy[trajectory_start_index:]
    if len(trajectory_xy) < 2:
        raise ValueError(
            "At least two valid trajectory points are required for plotting"
        )
    steps = tuple(range(trajectory_start_index, len(raw_trajectory_xy)))

    steps_total = _read_nonnegative_int(benchmark_record, "steps")
    expected_steps_total = len(raw_trajectory_xy) - 1
    if steps_total != expected_steps_total:
        raise ValueError(
            f"Benchmark steps={steps_total}, but trajectory contains "
            f"{len(raw_trajectory_xy)} points; expected steps={expected_steps_total}"
        )
    return trajectory_xy, steps, steps_total


def _read_phase1_end_step(
    benchmark_record: dict[str, Any],
    steps_total: int,
) -> int | None:
    if not benchmark_record.get("phase1_success"):
        return None
    phase1_end_step = _read_nonnegative_int(benchmark_record, "phase1_steps")
    if phase1_end_step > steps_total:
        raise ValueError(
            f"phase1_steps={phase1_end_step} exceeds benchmark steps={steps_total}"
        )
    return phase1_end_step


def _read_failure_reason(benchmark_record: dict[str, Any]) -> str:
    failure_value = benchmark_record.get("failure_reason")
    return str(failure_value) if failure_value else "SUCCESS"


def load_xy_trajectory_data(
    *,
    trajectory_jsonl_path: str | Path,
    benchmark_jsonl_path: str | Path,
    task_jsonl_path: str | Path,
    level: int,
    point_id: int,
    episode_id: int,
    trajectory_start_index: int,
) -> XYTrajectoryPlotData:
    """Load, join, validate, and clean the data required by the XY plot.

    ``trajectory_start_index`` is the first valid index in the raw trajectory.
    It is explicit by design: use 0 for a normal log and 1 for the verified
    reset-cache first point in the current L0/P7/E0 run.
    """

    episode_key = _validate_selection(
        level,
        point_id,
        episode_id,
        trajectory_start_index,
    )
    records = _load_episode_records(
        _resolve_input_file(trajectory_jsonl_path, "trajectory JSONL"),
        _resolve_input_file(benchmark_jsonl_path, "benchmark JSONL"),
        _resolve_input_file(task_jsonl_path, "task JSONL"),
        episode_key,
    )
    trajectory_xy, steps, steps_total = _prepare_trajectory(
        records.trajectory,
        records.benchmark,
        trajectory_start_index,
    )
    phase1_end_step = _read_phase1_end_step(records.benchmark, steps_total)

    return XYTrajectoryPlotData(
        level=level,
        point_id=point_id,
        episode_id=episode_id,
        env_id=str(records.task.get("env_id", "unknown")),
        trajectory_start_index=trajectory_start_index,
        steps=steps,
        trajectory_xy_cm=trajectory_xy,
        phase1_end_step=phase1_end_step,
        agent_xy_cm=_read_xy(records.task, "agent_loc"),
        injured_xy_cm=_read_xy(records.task, "injured_player_loc"),
        stretcher_xy_cm=_read_xy(records.task, "stretcher_loc"),
        ambulance_xy_cm=_read_xy(records.task, "ambulance_loc"),
        steps_total=steps_total,
        time_cost=_read_nonnegative_float(records.benchmark, "time_cost"),
        failure_reason=_read_failure_reason(records.benchmark),
    )

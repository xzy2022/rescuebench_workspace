#!/usr/bin/env python3
"""Find the latest paired NoMaD logs and render one XY trajectory."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from importlib import import_module
from pathlib import Path
from typing import Any, cast

if __package__ is None:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

_DATA_API = cast(Any, import_module("scripts.trajectory_plot.nomad_xy_data"))
_PLOT_API = cast(Any, import_module("scripts.trajectory_plot.nomad_xy_plot"))

_REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
_TASK_JSONL_DIRECTORY = (
    _REPOSITORY_ROOT
    / "repos"
    / "RescueBench"
    / "gym_rescue"
    / "envs"
    / "setting"
    / "test_jsonl"
)
_TRAJECTORY_NAME_PATTERN = re.compile(
    r"^trajectories_nomad_(?P<timestamp>\d{8}_\d{6})\.jsonl$"
)


@dataclass(frozen=True)
class NoMaDInputPaths:
    """The latest complete log pair and its level-specific task file."""

    trajectory_jsonl: Path
    benchmark_jsonl: Path
    task_jsonl: Path
    timestamp: str


@dataclass(frozen=True)
class EpisodeSelection:
    """The episode and trajectory slice forwarded to the data loader."""

    level: int = 0
    point_id: int = 1
    episode_id: int = 0
    trajectory_start_index: int = 0


def parse_args() -> argparse.Namespace:
    """Parse a log root, episode selection, and optional output override."""

    parser = argparse.ArgumentParser(
        description=(
            "Find the latest complete NoMaD JSONL pair under a log path and "
            "plot one XY trajectory."
        )
    )
    parser.add_argument("--log-path", type=Path, required=True)
    parser.add_argument("--level", type=int, default=0)
    parser.add_argument("--point-id", type=int, default=1)
    parser.add_argument("--episode-id", type=int, default=0)
    parser.add_argument("--trajectory-start-index", type=int, default=0)
    parser.add_argument(
        "--output",
        type=Path,
        help="Output PNG path; defaults beside the selected trajectory JSONL.",
    )
    return parser.parse_args()


def resolve_latest_nomad_inputs(log_path: str | Path, level: int) -> NoMaDInputPaths:
    """Resolve the newest same-timestamp trajectory/benchmark JSONL pair."""

    resolved_log_path = Path(log_path).expanduser().resolve()
    if not resolved_log_path.is_dir():
        raise NotADirectoryError(
            f"Log path does not exist or is not a directory: {resolved_log_path}"
        )

    paired_candidates: list[tuple[str, Path, Path]] = []
    for trajectory_path in resolved_log_path.rglob("trajectories_nomad_*.jsonl"):
        name_match = _TRAJECTORY_NAME_PATTERN.fullmatch(trajectory_path.name)
        if name_match is None:
            continue
        timestamp = name_match.group("timestamp")
        benchmark_path = trajectory_path.with_name(f"benchmark_nomad_{timestamp}.jsonl")
        if benchmark_path.is_file():
            paired_candidates.append(
                (timestamp, trajectory_path.resolve(), benchmark_path.resolve())
            )

    if not paired_candidates:
        raise FileNotFoundError(
            "No complete trajectories_nomad_<timestamp>.jsonl and "
            "benchmark_nomad_<timestamp>.jsonl pair was found under "
            f"{resolved_log_path}"
        )

    latest_timestamp = max(candidate[0] for candidate in paired_candidates)
    latest_candidates = [
        candidate for candidate in paired_candidates if candidate[0] == latest_timestamp
    ]
    if len(latest_candidates) != 1:
        locations = ", ".join(
            str(candidate[1].parent) for candidate in latest_candidates
        )
        raise ValueError(
            f"Multiple complete NoMaD log pairs have latest timestamp "
            f"{latest_timestamp}: {locations}"
        )

    timestamp, trajectory_jsonl, benchmark_jsonl = latest_candidates[0]
    task_jsonl = (_TASK_JSONL_DIRECTORY / f"level_{level}.jsonl").resolve()
    if not task_jsonl.is_file():
        raise FileNotFoundError(
            f"Level {level} task JSONL does not exist: {task_jsonl}"
        )

    return NoMaDInputPaths(
        trajectory_jsonl=trajectory_jsonl,
        benchmark_jsonl=benchmark_jsonl,
        task_jsonl=task_jsonl,
        timestamp=timestamp,
    )


def resolve_output_path(
    output_path: str | Path | None,
    inputs: NoMaDInputPaths,
    selection: EpisodeSelection,
) -> Path:
    """Use an explicit output path or build a collision-resistant default."""

    if output_path is not None:
        return Path(output_path).expanduser().resolve()
    return inputs.trajectory_jsonl.with_name(
        f"trajectory_xy_topdown_nomad_{inputs.timestamp}_"
        f"L{selection.level}_P{selection.point_id}_E{selection.episode_id}.png"
    )


def main() -> int:
    """Resolve the latest inputs, forward selection, and write the plot."""

    args = parse_args()
    selection = EpisodeSelection(
        level=args.level,
        point_id=args.point_id,
        episode_id=args.episode_id,
        trajectory_start_index=args.trajectory_start_index,
    )
    inputs = resolve_latest_nomad_inputs(args.log_path, selection.level)
    output_path = resolve_output_path(args.output, inputs, selection)
    plot_data = _DATA_API.load_xy_trajectory_data(
        trajectory_jsonl_path=inputs.trajectory_jsonl,
        benchmark_jsonl_path=inputs.benchmark_jsonl,
        task_jsonl_path=inputs.task_jsonl,
        level=selection.level,
        point_id=selection.point_id,
        episode_id=selection.episode_id,
        trajectory_start_index=selection.trajectory_start_index,
    )
    written_path = _PLOT_API.plot_xy_topdown(plot_data, output_path)

    print(f"trajectory_jsonl={inputs.trajectory_jsonl}")
    print(f"benchmark_jsonl={inputs.benchmark_jsonl}")
    print(f"task_jsonl={inputs.task_jsonl}")
    print(f"selected=L{plot_data.level}/P{plot_data.point_id}/E{plot_data.episode_id}")
    print(f"trajectory_start_index={plot_data.trajectory_start_index}")
    print(f"plotted_points={len(plot_data.trajectory_xy_cm)}")
    print(f"output={written_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

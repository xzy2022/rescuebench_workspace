#!/usr/bin/env python3
"""Load explicit RescueBench episode files and plot their XY trajectory."""

from __future__ import annotations

import argparse
import sys
from importlib import import_module
from pathlib import Path
from typing import Any, cast

if __package__ is None:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

_DATA_API = cast(Any, import_module("scripts.trajectory_plot.nomad_xy_data"))
_PLOT_API = cast(Any, import_module("scripts.trajectory_plot.nomad_xy_plot"))


def parse_args() -> argparse.Namespace:
    """Parse explicit input paths and the episode selection from the CLI."""

    parser = argparse.ArgumentParser(
        description="Load explicit RescueBench episode files and plot an XY trajectory."
    )
    parser.add_argument("--trajectory-jsonl", type=Path, required=True)
    parser.add_argument("--benchmark-jsonl", type=Path, required=True)
    parser.add_argument("--task-jsonl", type=Path, required=True)
    parser.add_argument("--level", type=int, required=True)
    parser.add_argument("--point-id", type=int, required=True)
    parser.add_argument("--episode-id", type=int, required=True)
    parser.add_argument("--trajectory-start-index", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    """Load the selected episode, write its plot, and report the output path."""

    args = parse_args()
    plot_data = _DATA_API.load_xy_trajectory_data(
        trajectory_jsonl_path=args.trajectory_jsonl,
        benchmark_jsonl_path=args.benchmark_jsonl,
        task_jsonl_path=args.task_jsonl,
        level=args.level,
        point_id=args.point_id,
        episode_id=args.episode_id,
        trajectory_start_index=args.trajectory_start_index,
    )
    output_path = _PLOT_API.plot_xy_topdown(plot_data, args.output)

    print(f"selected=L{plot_data.level}/P{plot_data.point_id}/E{plot_data.episode_id}")
    print(f"env_id={plot_data.env_id}")
    print(f"trajectory_start_index={plot_data.trajectory_start_index}")
    print(f"plotted_points={len(plot_data.trajectory_xy_cm)}")
    print(f"output={output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

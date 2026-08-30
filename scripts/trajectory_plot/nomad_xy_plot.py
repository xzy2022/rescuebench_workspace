"""Render a top-down RescueBench XY trajectory from validated plot data."""

from __future__ import annotations

import math
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.axes import Axes

from .nomad_xy_data import XYTrajectoryPlotData


def _add_target(
    axis: Axes,
    xy_cm: tuple[float, float],
    *,
    label: str,
    marker: str,
    color: str,
) -> tuple[float, float]:
    x_m, y_m = xy_cm[0] / 100.0, xy_cm[1] / 100.0
    axis.scatter(
        [x_m],
        [y_m],
        marker=marker,
        s=135,
        color=color,
        edgecolors="white",
        linewidths=1.2,
        label=label,
        zorder=7,
    )
    axis.annotate(
        label,
        (x_m, y_m),
        xytext=(7, 7),
        textcoords="offset points",
        fontsize=9,
        weight="bold",
        color=color,
    )
    return x_m, y_m


def plot_xy_topdown(
    plot_data: XYTrajectoryPlotData,
    output_path: str | Path,
) -> Path:
    """Plot already-loaded XY data and return the resolved output image path."""

    if len(plot_data.steps) != len(plot_data.trajectory_xy_cm):
        raise ValueError("plot_data steps and trajectory_xy_cm lengths differ")
    if len(plot_data.steps) < 2:
        raise ValueError("At least two trajectory points are required for plotting")

    steps = plot_data.steps
    xs_m = [point[0] / 100.0 for point in plot_data.trajectory_xy_cm]
    ys_m = [point[1] / 100.0 for point in plot_data.trajectory_xy_cm]
    resolved_output = Path(output_path).expanduser().resolve()
    resolved_output.parent.mkdir(parents=True, exist_ok=True)

    figure, axis = plt.subplots(figsize=(10.5, 8.5))
    try:
        phase1_end_step = plot_data.phase1_end_step
        if phase1_end_step is not None and phase1_end_step in steps:
            boundary = steps.index(phase1_end_step)
            axis.plot(
                xs_m[: boundary + 1],
                ys_m[: boundary + 1],
                color="#2563eb",
                linewidth=2.4,
                label=(f"Phase 1: find injured (steps {steps[0]}-{phase1_end_step})"),
                zorder=3,
            )
            axis.plot(
                xs_m[boundary:],
                ys_m[boundary:],
                color="#f97316",
                linewidth=2.1,
                label=(
                    f"Phase 2: find stretcher (steps {phase1_end_step}-{steps[-1]})"
                ),
                zorder=2,
            )
            axis.scatter(
                [xs_m[boundary]],
                [ys_m[boundary]],
                marker="P",
                s=115,
                color="#7c3aed",
                edgecolors="white",
                linewidths=1.0,
                label=f"Carry / phase switch (step {phase1_end_step})",
                zorder=8,
            )
        elif phase1_end_step is not None and phase1_end_step < steps[0]:
            axis.plot(
                xs_m,
                ys_m,
                color="#f97316",
                linewidth=2.1,
                label=(f"Phase 2: find stretcher (steps {steps[0]}-{steps[-1]})"),
                zorder=2,
            )
        else:
            axis.plot(
                xs_m,
                ys_m,
                color="#2563eb",
                linewidth=2.3,
                label="Recorded protagonist trajectory",
                zorder=3,
            )

        axis.scatter(
            [xs_m[0]],
            [ys_m[0]],
            marker="o",
            s=105,
            color="#16a34a",
            edgecolors="white",
            linewidths=1.2,
            label=f"Recorded start (step {steps[0]})",
            zorder=8,
        )
        axis.scatter(
            [xs_m[-1]],
            [ys_m[-1]],
            marker="X",
            s=125,
            color="#dc2626",
            edgecolors="white",
            linewidths=1.1,
            label=f"End (step {steps[-1]})",
            zorder=8,
        )

        _add_target(
            axis,
            plot_data.agent_xy_cm,
            label="Configured agent start",
            marker="h",
            color="#166534",
        )
        _add_target(
            axis,
            plot_data.injured_xy_cm,
            label="Injured",
            marker="*",
            color="#b91c1c",
        )
        stretcher_xy_m = _add_target(
            axis,
            plot_data.stretcher_xy_cm,
            label="Stretcher",
            marker="s",
            color="#9333ea",
        )
        _add_target(
            axis,
            plot_data.ambulance_xy_cm,
            label="Ambulance",
            marker="D",
            color="#0891b2",
        )

        phase2_start = phase1_end_step if phase1_end_step is not None else steps[0]
        phase2_indices = [
            index for index, step in enumerate(steps) if step >= phase2_start
        ]
        if phase2_indices:
            nearest_index = min(
                phase2_indices,
                key=lambda index: math.hypot(
                    xs_m[index] - stretcher_xy_m[0],
                    ys_m[index] - stretcher_xy_m[1],
                ),
            )
            nearest_distance_m = math.hypot(
                xs_m[nearest_index] - stretcher_xy_m[0],
                ys_m[nearest_index] - stretcher_xy_m[1],
            )
            axis.scatter(
                [xs_m[nearest_index]],
                [ys_m[nearest_index]],
                marker="v",
                s=105,
                color="#a16207",
                edgecolors="white",
                linewidths=1.0,
                label=(
                    "Closest protagonist pose to stretcher "
                    f"(step {steps[nearest_index]}, {nearest_distance_m:.2f} m)"
                ),
                zorder=8,
            )

        axis.set_title(
            f"NoMaD Recorded XY Trajectory | "
            f"L{plot_data.level} P{plot_data.point_id} E{plot_data.episode_id} | "
            f"{plot_data.steps_total} steps | {plot_data.time_cost:.1f} s | "
            f"{plot_data.failure_reason}",
            fontsize=14,
            weight="bold",
            pad=14,
        )
        axis.set_xlabel("Unreal world X (m)")
        axis.set_ylabel("Unreal world Y (m)")
        axis.set_aspect("equal", adjustable="datalim")
        axis.grid(True, linestyle="--", linewidth=0.7, alpha=0.35)
        axis.legend(
            loc="upper left",
            bbox_to_anchor=(1.02, 1.0),
            borderaxespad=0.0,
            fontsize=8.8,
        )
        axis.margins(0.08)
        figure.tight_layout()
        figure.savefig(resolved_output, dpi=220, bbox_inches="tight")
    finally:
        plt.close(figure)

    return resolved_output

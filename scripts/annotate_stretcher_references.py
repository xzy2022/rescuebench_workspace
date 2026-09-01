"""Interactively select one stretcher reference image for each level/point."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tkinter as tk
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from tkinter import messagebox
from typing import Any

from PIL import Image, ImageDraw, ImageTk

FILENAME_PATTERN = re.compile(r"^level_(\d+)_(\d+)_(\d+)UU\.png$")
DEFAULT_INPUT_DIRS = (
    Path("tmp/stretcher/stretcher_v2_1"),
    Path("tmp/stretcher/stretcher_v2_2"),
)
DEFAULT_WORK_DIR = Path("tmp/stretcher/annotation_work")
DEFAULT_OUTPUT_JSON = Path("tmp/stretcher/stretcher_selection.json")
GroupKey = tuple[int, int]


def utc_now() -> str:
    """Return a compact UTC timestamp."""
    return datetime.now(UTC).isoformat(timespec="seconds")


def portable_path(path: Path) -> str:
    """Prefer a current-working-directory-relative path in saved records."""
    resolved = path.resolve()
    try:
        return resolved.relative_to(Path.cwd().resolve()).as_posix()
    except ValueError:
        return resolved.as_posix()


def path_identity(path_value: str | Path) -> str:
    """Normalize a stored or live path for identity comparisons on Windows."""
    path = Path(path_value)
    if not path.is_absolute():
        path = Path.cwd() / path
    return os.path.normcase(str(path.resolve()))


@dataclass(frozen=True)
class Candidate:
    """One captured image and its sidecar metadata."""

    image_path: Path
    metadata_path: Path
    source_dir: Path
    level: int
    point_id: int
    distance_uu: int
    metadata: dict[str, Any]

    @property
    def image_ref(self) -> str:
        """Return the path representation stored in output JSON."""
        return portable_path(self.image_path)

    def as_record(self) -> dict[str, Any]:
        """Return downstream-useful candidate provenance."""
        return {
            "image": self.image_ref,
            "metadata": portable_path(self.metadata_path),
            "source_dir": portable_path(self.source_dir),
            "capture_distance_uu": self.distance_uu,
            "sha256": self.metadata.get("sha256"),
            "env_id": self.metadata.get("env_id"),
            "scene": self.metadata.get("scene"),
            "image_size": self.metadata.get("image_size"),
        }


@dataclass(frozen=True)
class ImageGroup:
    """All candidates sharing one level and point id."""

    level: int
    point_id: int
    candidates: tuple[Candidate, ...]

    @property
    def key(self) -> GroupKey:
        """Return the canonical group key."""
        return self.level, self.point_id


@dataclass
class Cursor:
    """Current position in the annotation inventory."""

    group_index: int = 0
    candidate_index: int = 0


@dataclass
class SessionState:
    """Mutable decisions and cursor restored from or saved to JSON."""

    created_at_utc: str
    decisions: dict[GroupKey, dict[str, Any]]
    cursor: Cursor


@dataclass(frozen=True)
class OutputPaths:
    """Persistent annotation destinations."""

    work_dir: Path
    output_json: Path

    @property
    def event_log(self) -> Path:
        """Return the append-only event-log path."""
        return self.work_dir / "annotation_events.jsonl"


def read_candidate(path: Path, source_dir: Path) -> Candidate:
    """Parse and validate one candidate image and its JSON sidecar."""
    match = FILENAME_PATTERN.fullmatch(path.name)
    if match is None:
        raise ValueError(f"unsupported image filename: {path}")
    level, point_id, distance_uu = (int(value) for value in match.groups())
    metadata_path = path.with_suffix(".json")
    if not metadata_path.is_file():
        raise ValueError(f"missing metadata sidecar: {metadata_path}")
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read metadata: {metadata_path}: {exc}") from exc
    expected = (level, point_id, distance_uu, path.name, "captured")
    actual = (
        metadata.get("level"),
        metadata.get("point_id"),
        int(metadata.get("capture_distance_uu", -1)),
        metadata.get("filename"),
        metadata.get("status"),
    )
    if actual != expected:
        raise ValueError(
            f"metadata does not match image filename/status: {metadata_path}"
        )
    return Candidate(
        path.resolve(),
        metadata_path.resolve(),
        source_dir.resolve(),
        level,
        point_id,
        distance_uu,
        metadata,
    )


def discover_groups(input_dirs: list[Path]) -> list[ImageGroup]:
    """Discover immediate-child PNGs and group them by level and point."""
    grouped: dict[GroupKey, list[Candidate]] = {}
    for source_dir in input_dirs:
        if not source_dir.is_dir():
            raise ValueError(f"input directory does not exist: {source_dir}")
        for path in sorted(source_dir.glob("*.png")):
            if FILENAME_PATTERN.fullmatch(path.name) is None:
                raise ValueError(f"unsupported root PNG filename: {path}")
            candidate = read_candidate(path, source_dir)
            grouped.setdefault((candidate.level, candidate.point_id), []).append(
                candidate
            )
    if not grouped:
        raise ValueError("no candidate PNG files were found")
    groups = []
    for (level, point_id), candidates in sorted(grouped.items()):
        groups.append(ImageGroup(level, point_id, tuple(candidates)))
    return groups


def load_state(output_json: Path, groups: list[ImageGroup]) -> SessionState:
    """Load a prior output file and verify that its decisions remain resolvable."""
    if not output_json.exists():
        return SessionState(utc_now(), {}, Cursor())
    try:
        payload = json.loads(output_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot load existing output JSON: {exc}") from exc
    if payload.get("schema_version") != 1:
        raise ValueError("unsupported output JSON schema_version")
    group_map = {group.key: group for group in groups}
    decisions: dict[GroupKey, dict[str, Any]] = {}
    for record in payload.get("records", []):
        key = int(record["level"]), int(record["point_id"])
        if key not in group_map:
            raise ValueError(f"saved group is absent from current inputs: {key}")
        if record.get("status") == "selected":
            selected = record.get("selected_candidate", {}).get("image")
            identities = {
                path_identity(candidate.image_ref)
                for candidate in group_map[key].candidates
            }
            if not selected or path_identity(selected) not in identities:
                raise ValueError(f"saved selected image is absent for group: {key}")
        decisions[key] = record
    current = payload.get("progress", {}).get("current_group")
    cursor_key = None
    candidate_index = 0
    if current:
        cursor_key = int(current["level"]), int(current["point_id"])
        candidate_index = int(current.get("candidate_index", 0))
    if cursor_key is not None:
        try:
            group_index = next(
                index for index, group in enumerate(groups) if group.key == cursor_key
            )
        except StopIteration as exc:
            raise ValueError(
                f"saved current group is absent from current inputs: {cursor_key}"
            ) from exc
    else:
        group_index = next(
            (index for index, group in enumerate(groups) if group.key not in decisions),
            len(groups),
        )
    return SessionState(
        payload.get("created_at_utc", utc_now()),
        decisions,
        Cursor(group_index, candidate_index),
    )


def missing_groups(groups: list[ImageGroup]) -> list[dict[str, int]]:
    """Report gaps from point zero through the largest observed point per level."""
    points_by_level: dict[int, set[int]] = {}
    for group in groups:
        points_by_level.setdefault(group.level, set()).add(group.point_id)
    missing = []
    for level, points in sorted(points_by_level.items()):
        for point_id in range(max(points) + 1):
            if point_id not in points:
                missing.append({"level": level, "point_id": point_id})
    return missing


class AnnotationApp:
    """Tkinter annotation window and persistent state controller."""

    def __init__(
        self,
        root: tk.Tk,
        groups: list[ImageGroup],
        input_dirs: list[Path],
        paths: OutputPaths,
        loaded: SessionState,
    ) -> None:
        self.root = root
        self.groups = groups
        self.input_dirs = input_dirs
        self.paths = paths
        self.state = loaded
        self.image_label = tk.Label(root, bg="#202020", fg="white")
        self.status_label = tk.Label(root, anchor="w", justify="left")
        self._configure_window()
        self.render()
        self.save_state()

    def _configure_window(self) -> None:
        self.root.title("Stretcher reference selector")
        self.root.configure(bg="#202020")
        self.image_label.pack(fill="both", expand=True, padx=8, pady=8)
        self.status_label.pack(fill="x", padx=10, pady=(0, 8))
        help_text = (
            "←/→ 切换候选    1 选择    2 全部跳过    Backspace 回退    Esc 保存退出"
        )
        tk.Label(self.root, text=help_text, anchor="w").pack(fill="x", padx=10)
        self.root.bind("<Left>", self.previous_candidate)
        self.root.bind("<Right>", self.next_candidate)
        self.root.bind("<Key-1>", self.select_current)
        self.root.bind("<Key-2>", self.skip_current)
        self.root.bind("<BackSpace>", self.go_back)
        self.root.bind("<Escape>", self.close)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.minsize(720, 620)

    def current_group(self) -> ImageGroup | None:
        """Return the current group, or None after all groups are resolved."""
        if self.state.cursor.group_index >= len(self.groups):
            return None
        return self.groups[self.state.cursor.group_index]

    def render(self) -> None:
        """Render the current image and progress status."""
        group = self.current_group()
        if group is None:
            self.image_label.configure(
                image="",
                text="全部分组已处理\n可按 Backspace 回退修改最后一组",
                font=("Segoe UI", 20),
            )
            self.image_label.image = None
            self._render_status(None)
            return
        self.state.cursor.candidate_index %= len(group.candidates)
        candidate = group.candidates[self.state.cursor.candidate_index]
        with Image.open(candidate.image_path) as source:
            image = source.convert("RGB")
        image.thumbnail((1100, 720), Image.Resampling.LANCZOS)
        decision = self.state.decisions.get(group.key)
        selected = None if decision is None else decision.get("selected_candidate")
        if selected and path_identity(selected["image"]) == path_identity(
            candidate.image_ref
        ):
            self._draw_check(image)
        photo = ImageTk.PhotoImage(image)
        self.image_label.configure(image=photo, text="")
        self.image_label.image = photo
        self._render_status(candidate)

    @staticmethod
    def _draw_check(image: Image.Image) -> None:
        width, _height = image.size
        size = max(48, min(image.size) // 7)
        margin = max(16, size // 3)
        start = (width - margin - size, margin + size // 2)
        middle = (width - margin - size * 2 // 3, margin + size)
        end = (width - margin, margin)
        ImageDraw.Draw(image).line(
            (start, middle, end), fill=(0, 230, 90), width=max(8, size // 7)
        )

    def _render_status(self, candidate: Candidate | None) -> None:
        selected = sum(
            item["status"] == "selected" for item in self.state.decisions.values()
        )
        skipped = sum(
            item["status"] == "skipped" for item in self.state.decisions.values()
        )
        if candidate is None:
            detail = "处理完成"
        else:
            group = self.groups[self.state.cursor.group_index]
            detail = (
                f"组 {self.state.cursor.group_index + 1}/{len(self.groups)}  "
                f"level={group.level} point={group.point_id}  "
                f"候选 {self.state.cursor.candidate_index + 1}/"
                f"{len(group.candidates)}  "
                f"distance={candidate.distance_uu}UU\n{candidate.image_ref}"
            )
        self.status_label.configure(
            text=f"{detail}\n已选择 {selected}  已跳过 {skipped}  待处理 "
            f"{len(self.groups) - len(self.state.decisions)}"
        )

    def previous_candidate(self, _event: tk.Event[Any] | None = None) -> None:
        """Cycle to the previous candidate in the current group."""
        group = self.current_group()
        if group is None:
            return
        self.state.cursor.candidate_index = (
            self.state.cursor.candidate_index - 1
        ) % len(group.candidates)
        self.save_state()
        self.render()

    def next_candidate(self, _event: tk.Event[Any] | None = None) -> None:
        """Cycle to the next candidate in the current group."""
        group = self.current_group()
        if group is None:
            return
        self.state.cursor.candidate_index = (
            self.state.cursor.candidate_index + 1
        ) % len(group.candidates)
        self.save_state()
        self.render()

    def select_current(self, _event: tk.Event[Any] | None = None) -> None:
        """Select the visible candidate and advance."""
        group = self.current_group()
        if group is None:
            return
        candidate = group.candidates[self.state.cursor.candidate_index]
        record = self._base_record(group, "selected")
        record["target_filename"] = f"level_{group.level}_{group.point_id}.png"
        record["selected_candidate"] = candidate.as_record()
        self.state.decisions[group.key] = record
        self._append_event("selected", group, candidate.as_record())
        self._advance()

    def skip_current(self, _event: tk.Event[Any] | None = None) -> None:
        """Reject all candidates in the current group and advance."""
        group = self.current_group()
        if group is None:
            return
        record = self._base_record(group, "skipped")
        record["reason"] = "manual_reject_all"
        self.state.decisions[group.key] = record
        self._append_event("skipped", group)
        self._advance()

    def _base_record(self, group: ImageGroup, status: str) -> dict[str, Any]:
        return {
            "level": group.level,
            "point_id": group.point_id,
            "status": status,
            "decided_at_utc": utc_now(),
            "candidates": [item.as_record() for item in group.candidates],
        }

    def _advance(self) -> None:
        self.state.cursor.group_index += 1
        self.state.cursor.candidate_index = 0
        while self.state.cursor.group_index < len(self.groups):
            if (
                self.groups[self.state.cursor.group_index].key
                not in self.state.decisions
            ):
                break
            self.state.cursor.group_index += 1
        self.save_state()
        self.render()

    def go_back(self, _event: tk.Event[Any] | None = None) -> None:
        """Undo the previous group's decision and display it again."""
        if self.state.cursor.group_index == 0:
            return
        self.state.cursor.group_index -= 1
        group = self.groups[self.state.cursor.group_index]
        previous = self.state.decisions.pop(group.key, None)
        self.state.cursor.candidate_index = self._selected_index(group, previous)
        self._append_event("undo", group, previous)
        self.save_state()
        self.render()

    @staticmethod
    def _selected_index(group: ImageGroup, previous: dict[str, Any] | None) -> int:
        if previous and previous.get("status") == "selected":
            selected = previous["selected_candidate"]["image"]
            for index, candidate in enumerate(group.candidates):
                if path_identity(selected) == path_identity(candidate.image_ref):
                    return index
        return 0

    def _append_event(
        self,
        action: str,
        group: ImageGroup,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.paths.work_dir.mkdir(parents=True, exist_ok=True)
        event = {
            "recorded_at_utc": utc_now(),
            "action": action,
            "level": group.level,
            "point_id": group.point_id,
        }
        if details is not None:
            event["details"] = details
        with self.paths.event_log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def save_state(self) -> None:
        """Atomically save the canonical, resumable annotation result."""
        current = self.current_group()
        current_record = None
        if current is not None:
            current_record = {
                "level": current.level,
                "point_id": current.point_id,
                "candidate_index": self.state.cursor.candidate_index,
            }
        records = [
            self.state.decisions[group.key]
            for group in self.groups
            if group.key in self.state.decisions
        ]
        selected = sum(item["status"] == "selected" for item in records)
        skipped = sum(item["status"] == "skipped" for item in records)
        payload = {
            "schema_version": 1,
            "created_at_utc": self.state.created_at_utc,
            "updated_at_utc": utc_now(),
            "source_dirs": [portable_path(path) for path in self.input_dirs],
            "progress": {
                "total_groups": len(self.groups),
                "selected_groups": selected,
                "skipped_groups": skipped,
                "pending_groups": len(self.groups) - len(records),
                "current_group": current_record,
            },
            "records": records,
            "source_missing_groups": missing_groups(self.groups),
        }
        self.paths.output_json.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.paths.output_json.with_suffix(
            self.paths.output_json.suffix + ".tmp"
        )
        temporary.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        temporary.replace(self.paths.output_json)

    def close(self, _event: tk.Event[Any] | None = None) -> None:
        """Save and close the annotation window."""
        try:
            self.save_state()
        except OSError as exc:
            messagebox.showerror("保存失败", str(exc))
            return
        self.root.destroy()


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input-dir",
        action="append",
        type=Path,
        help="候选图片目录；可重复指定。默认读取 stretcher_v2_1 和 v2_2。",
    )
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--output-json", type=Path, default=DEFAULT_OUTPUT_JSON)
    return parser


def main() -> int:
    """Run the annotation application."""
    args = build_parser().parse_args()
    input_dirs = args.input_dir or list(DEFAULT_INPUT_DIRS)
    try:
        groups = discover_groups(input_dirs)
        loaded = load_state(args.output_json, groups)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    root = tk.Tk()
    AnnotationApp(
        root, groups, input_dirs, OutputPaths(args.work_dir, args.output_json), loaded
    )
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

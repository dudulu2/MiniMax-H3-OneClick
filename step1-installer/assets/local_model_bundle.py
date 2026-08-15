from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import uuid
from pathlib import Path
from typing import Any, Iterable

MODEL_KEYS = ("diffusion_model", "text_encoder", "video_vae", "audio_vae")
COPY_CHUNK = 8 * 1024 * 1024


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def resolve_profile(profiles_path: Path, profile_id: str) -> dict[str, Any]:
    payload = load_json(profiles_path)
    for profile in payload.get("profiles", []):
        if profile.get("id") == profile_id:
            return profile
    raise ValueError(f"unknown profile: {profile_id}")


def resolve_models(catalog_path: Path, profile: dict[str, Any]) -> tuple[dict[str, Any], ...]:
    catalog = load_json(catalog_path)
    by_path = {str(item["path"]): item for item in catalog}
    models: list[dict[str, Any]] = []
    for key in MODEL_KEYS:
        relative = str(profile[key]).replace("\\", "/")
        if relative.startswith("/") or ".." in Path(relative).parts:
            raise ValueError(f"unsafe model path in profile: {relative}")
        item = by_path.get(relative)
        if not item:
            raise ValueError(f"profile references a model absent from catalog: {relative}")
        size = item.get("size")
        sha256 = item.get("sha256")
        if not isinstance(size, int) or size <= 0:
            raise ValueError(f"invalid catalog size for {relative}")
        if not isinstance(sha256, str) or len(sha256) != 64:
            raise ValueError(f"invalid catalog SHA-256 for {relative}")
        models.append(
            {
                "path": relative,
                "name": Path(relative).name,
                "size": size,
                "sha256": sha256.upper(),
            }
        )
    return tuple(models)


def is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


def add_candidate(
    result: list[Path],
    seen: set[str],
    candidate: Path,
    bundle_root: Path,
    destination: Path,
) -> None:
    try:
        if not candidate.exists() or not candidate.is_file() or candidate.is_symlink():
            return
        resolved = candidate.resolve()
        if not is_within(resolved, bundle_root):
            return
        if resolved == destination.resolve():
            return
        key = os.path.normcase(str(resolved))
        if key in seen:
            return
        seen.add(key)
        result.append(resolved)
    except OSError:
        return


def walk_exact_name(root: Path, name: str) -> Iterable[Path]:
    """Walk the package tree without following directory symlinks/junctions."""
    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        safe_dirs: list[str] = []
        for directory in dirs:
            child = current_path / directory
            try:
                if child.is_symlink():
                    continue
                safe_dirs.append(directory)
            except OSError:
                continue
        dirs[:] = safe_dirs
        for filename in files:
            if filename.casefold() == name.casefold():
                yield current_path / filename


def local_candidates(bundle_root: Path, relative: str, destination: Path) -> list[Path]:
    relative_path = Path(*relative.split("/"))
    name = relative_path.name
    preferred = (
        bundle_root / "step1-installer" / "models" / relative_path,
        bundle_root / "models" / relative_path,
        bundle_root / "step1-installer" / "assets" / "models" / relative_path,
        bundle_root / relative_path,
        bundle_root / "step1-installer" / name,
        bundle_root / name,
    )

    result: list[Path] = []
    seen: set[str] = set()
    for candidate in preferred:
        add_candidate(result, seen, candidate, bundle_root, destination)

    # Compatibility fallback: users may already have copied the exact model
    # files elsewhere inside the extracted one-click package. Search only this
    # package tree, never whole disks or the user's installation drive.
    for candidate in walk_exact_name(bundle_root, name):
        add_candidate(result, seen, candidate, bundle_root, destination)
    return result


def copy_and_verify(candidate: Path, destination: Path, model: dict[str, Any]) -> bool:
    expected_size = int(model["size"])
    try:
        if candidate.stat().st_size != expected_size:
            print(
                f"Ignoring local model with wrong size: {candidate} "
                f"({candidate.stat().st_size} != {expected_size})",
                flush=True,
            )
            return False
    except OSError as exc:
        print(f"Ignoring unreadable local model: {candidate}: {exc}", flush=True)
        return False

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.local-{uuid.uuid4().hex}.tmp")
    digest = hashlib.sha256()
    copied = 0
    last_report_gib = -1

    try:
        print(f"Checking bundled model: {candidate}", flush=True)
        with candidate.open("rb") as source, temporary.open("xb") as output:
            while True:
                block = source.read(COPY_CHUNK)
                if not block:
                    break
                output.write(block)
                digest.update(block)
                copied += len(block)
                gib = copied // (1024**3)
                if gib != last_report_gib:
                    last_report_gib = gib
                    print(
                        f"  local copy {model['name']}: "
                        f"{copied / (1024**3):.1f}/{expected_size / (1024**3):.1f} GiB",
                        flush=True,
                    )
            output.flush()
            os.fsync(output.fileno())

        actual_hash = digest.hexdigest().upper()
        if copied != expected_size or actual_hash != str(model["sha256"]).upper():
            print(
                f"Ignoring local model that failed verification: {candidate}; "
                f"size={copied}/{expected_size}; SHA256={actual_hash}",
                flush=True,
            )
            temporary.unlink(missing_ok=True)
            return False

        # The old destination (including a resumable network prefix) is left
        # untouched until the local candidate has been copied and verified.
        os.replace(temporary, destination)
        shutil.rmtree(destination.with_name(destination.name + ".parts"), ignore_errors=True)
        print(f"Local model verified and staged: {destination}", flush=True)
        return True
    except Exception as exc:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        print(f"Local model candidate could not be staged: {candidate}: {exc}", flush=True)
        return False


def stage_local_models(
    bundle_root: Path,
    comfy_root: Path,
    catalog_path: Path,
    profiles_path: Path,
    profile_id: str,
) -> int:
    bundle_root = bundle_root.resolve()
    comfy_root = comfy_root.resolve()
    if not bundle_root.is_dir():
        raise ValueError(f"bundle root does not exist: {bundle_root}")

    profile = resolve_profile(profiles_path, profile_id)
    models = resolve_models(catalog_path, profile)
    staged = 0

    print(f"Local model search root: {bundle_root}", flush=True)
    for model in models:
        relative_path = Path(*str(model["path"]).split("/"))
        destination = comfy_root / "models" / relative_path

        # A complete-size installed file is left in place. The normal model
        # downloader immediately following this helper performs the authoritative
        # SHA-256 verification and will not access the network when it is valid.
        try:
            if destination.exists() and destination.stat().st_size == int(model["size"]):
                print(
                    f"Installed model already has the expected size; leaving it for normal SHA-256 verification: "
                    f"{destination}",
                    flush=True,
                )
                continue
        except OSError:
            pass

        candidates = local_candidates(bundle_root, str(model["path"]), destination)
        if not candidates:
            print(f"No bundled candidate found for {model['path']}; network/resume fallback remains available.", flush=True)
            continue

        for candidate in candidates:
            if copy_and_verify(candidate, destination, model):
                staged += 1
                break
        else:
            print(
                f"No bundled candidate passed verification for {model['path']}; "
                "network/resume fallback remains available.",
                flush=True,
            )

    print(f"Local model staging complete: {staged}/{len(models)} model(s) supplied by the installer package.", flush=True)
    return staged


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-root", type=Path, required=True)
    parser.add_argument("--comfy-root", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--profiles", type=Path, required=True)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()

    stage_local_models(
        args.bundle_root,
        args.comfy_root,
        args.catalog,
        args.profiles,
        args.profile,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: local model staging failed: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)

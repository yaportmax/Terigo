#!/usr/bin/env python3

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHOT_MANIFEST = ROOT / "AppStore" / "SubmissionAssets" / "screenshots" / "shot_manifest.json"
RAW_ROOT = ROOT / "AppStore" / "SubmissionAssets" / "screenshots" / "raw_iPhone17"
FINAL_ROOT = ROOT / "AppStore" / "SubmissionAssets" / "screenshots" / "final_6_9_inch"
SOURCE_OVERRIDE_ROOT = ROOT / "AppStore" / "SubmissionAssets" / "screenshots" / "source_overrides"
FINAL_MANIFEST_PATH = FINAL_ROOT / "final_shot_manifest.json"
COMPOSER = ROOT / "Scripts" / "compose_app_store_screenshot.py"

APP_BUNDLE_ID = "com.myaport.RouteVault"
SHOTS = [
    {
        "id": "lists-sharing",
        "template": "01-lists-sharing-template",
        "raw_capture": "01-lists-sharing-raw.png",
        "final_output": "01-lists-sharing.png",
        "marketing_title": "Lists and sharing",
        "launch_args": ["--app-store-shot=lists"],
        "settle_delay": 9.0,
        "source_override": "02-lists-sharing-device.png",
    },
    {
        "id": "map-browse",
        "template": "02-map-browse-template",
        "raw_capture": "02-map-browse-raw.png",
        "final_output": "02-map-browse.png",
        "marketing_title": "Map browse",
        "launch_args": ["--app-store-shot=map-browse-san-francisco"],
        "settle_delay": 10.0,
        "source_override": "03-map-browse-device.png",
    },
    {
        "id": "stackable-filters",
        "template": "03-stackable-filters-template",
        "raw_capture": "03-stackable-filters-raw.png",
        "final_output": "03-stackable-filters.png",
        "marketing_title": "Stackable filters",
        "launch_args": ["--app-store-shot=filters"],
        "settle_delay": 9.0,
        "source_override": "04-stackable-filters-device.png",
    },
    {
        "id": "live-navigation",
        "template": "04-live-navigation-template",
        "raw_capture": "04-live-navigation-raw.png",
        "final_output": "04-live-navigation.png",
        "marketing_title": "Live navigation",
        "launch_args": ["--app-store-shot=live-tracking"],
        "settle_delay": 10.0,
        "source_override": "05-live-navigation-device.png",
    },
]


def run(args: list[str], *, quiet: bool = False) -> None:
    stdout = subprocess.DEVNULL if quiet else None
    stderr = subprocess.DEVNULL if quiet else None
    subprocess.run(args, check=True, text=True, stdout=stdout, stderr=stderr)


def ensure_prerequisites() -> None:
    booted_devices = subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted"], text=True)
    if "Booted" not in booted_devices:
        raise SystemExit("Boot an iPhone simulator first, then rerun this script.")

    installed_apps = subprocess.check_output(["xcrun", "simctl", "listapps", "booted"], text=True)
    if APP_BUNDLE_ID not in installed_apps:
        raise SystemExit(
            f"{APP_BUNDLE_ID} is not installed on the booted simulator. "
            "Install the app first, then rerun this script."
        )


def override_path_for(shot: dict) -> Path | None:
    source_override = shot.get("source_override")
    if not source_override:
        return None

    override_path = SOURCE_OVERRIDE_ROOT / source_override
    return override_path if override_path.exists() else None


def clear_previous_outputs() -> None:
    for directory in (RAW_ROOT, FINAL_ROOT):
        directory.mkdir(parents=True, exist_ok=True)
        for png_path in directory.glob("*.png"):
            png_path.unlink()


def relaunch_for_shot(shot: dict) -> None:
    terminate_app()
    run(["xcrun", "simctl", "launch", "booted", APP_BUNDLE_ID, *shot["launch_args"]], quiet=True)
    time.sleep(shot["settle_delay"])


def terminate_app() -> None:
    subprocess.run(
        ["xcrun", "simctl", "terminate", "booted", APP_BUNDLE_ID],
        check=False,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def activate_simulator() -> None:
    run(["osascript", "-e", 'tell application "Simulator" to activate'], quiet=True)
    time.sleep(0.2)


def capture(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    run(["xcrun", "simctl", "io", "booted", "screenshot", str(path)], quiet=True)


def materialize_raw_capture(shot: dict, destination: Path) -> None:
    override_path = override_path_for(shot)
    if override_path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(override_path, destination)
        return

    capture(destination)


def compose(template: str, capture_path: Path, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            sys.executable,
            str(COMPOSER),
            "--template",
            template,
            "--capture",
            str(capture_path),
            "--output",
            str(output_path),
        ],
        quiet=True,
    )


def load_template_specs() -> dict[str, dict]:
    specs = json.loads(SHOT_MANIFEST.read_text())
    return {spec["filename"].removesuffix(".png"): spec for spec in specs}


def main() -> int:
    shots_requiring_simulator = [shot for shot in SHOTS if override_path_for(shot) is None]
    if shots_requiring_simulator:
        ensure_prerequisites()

    clear_previous_outputs()

    RAW_ROOT.mkdir(parents=True, exist_ok=True)
    FINAL_ROOT.mkdir(parents=True, exist_ok=True)
    template_specs = load_template_specs()
    final_manifest: list[dict] = []
    used_simulator = False

    try:
        for shot in SHOTS:
            if override_path_for(shot) is None:
                relaunch_for_shot(shot)
                activate_simulator()
                used_simulator = True

            raw_capture_path = RAW_ROOT / shot["raw_capture"]
            final_output_path = FINAL_ROOT / shot["final_output"]

            materialize_raw_capture(shot, raw_capture_path)
            compose(shot["template"], raw_capture_path, final_output_path)

            spec = template_specs[shot["template"]]
            final_manifest.append(
                {
                    "id": shot["id"],
                    "marketing_title": shot["marketing_title"],
                    "template": f"AppStore/SubmissionAssets/screenshots/6_9_inch_templates/{spec['filename']}",
                    "raw_capture": str(raw_capture_path.relative_to(ROOT)),
                    "final_output": str(final_output_path.relative_to(ROOT)),
                    "required_display_class": spec["required_display_class"],
                    "accepted_portrait_sizes": spec["accepted_portrait_sizes"],
                    "actions": [],
                    "launch_args": shot["launch_args"],
                }
            )
    finally:
        if used_simulator:
            terminate_app()

    FINAL_MANIFEST_PATH.write_text(json.dumps(final_manifest, indent=2) + "\n")
    print(f"Wrote {FINAL_MANIFEST_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

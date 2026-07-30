#!/usr/bin/env python3
"""Static safety checks for the public Terigo repository."""

from __future__ import annotations

import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

REQUIRED_PATHS = [
    ROOT / "LICENSE",
    ROOT / "README.md",
    ROOT / "SECURITY.md",
    ROOT / "StravaVault" / "Info.plist",
    ROOT / "StravaVault" / "PrivacyInfo.xcprivacy",
    ROOT / "StravaVaultClean.xcodeproj" / "project.pbxproj",
    ROOT
    / "StravaVaultClean.xcodeproj"
    / "project.xcworkspace"
    / "contents.xcworkspacedata",
    ROOT / "supabase" / "functions" / "account-bootstrap" / "index.ts",
    ROOT / "supabase" / "functions" / "delete-account" / "index.ts",
]

FORBIDDEN_PATHS = [
    ROOT / ".env",
    ROOT / "Configuration" / "Secrets.xcconfig",
    ROOT / "Configuration" / "DeveloperSigning.xcconfig",
    ROOT / "AppStore" / "ExportOptions-app-store.plist",
    ROOT / "supabase" / ".local-backend",
    ROOT / "supabase" / ".temp",
]

PRIVATE_SUFFIXES = {
    ".cer",
    ".ipa",
    ".mobileprovision",
    ".p12",
    ".p8",
    ".pem",
}

TEXT_SUFFIXES = {
    "",
    ".entitlements",
    ".html",
    ".js",
    ".json",
    ".md",
    ".plist",
    ".py",
    ".sh",
    ".sql",
    ".swift",
    ".ts",
    ".xcconfig",
    ".xcprivacy",
    ".xcscheme",
    ".yml",
    ".yaml",
}

SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\bgh[opusr]_[A-Za-z0-9]{30,}\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "Mapbox token": re.compile(r"\b(?:pk|sk)\.[A-Za-z0-9._-]{30,}\b"),
    "JWT": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
}


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def readable_text(path: Path) -> str | None:
    if path.suffix.lower() not in TEXT_SUFFIXES:
        return None
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


def main() -> int:
    errors: list[str] = []

    for path in REQUIRED_PATHS:
        if not path.exists():
            fail(errors, f"missing required path: {path.relative_to(ROOT)}")

    for path in FORBIDDEN_PATHS:
        if path.exists():
            fail(errors, f"forbidden local path is present: {path.relative_to(ROOT)}")

    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts:
            continue

        relative = path.relative_to(ROOT)
        suffix = path.suffix.lower()
        if suffix in PRIVATE_SUFFIXES:
            fail(errors, f"private artifact type is present: {relative}")
        if path.stat().st_size > 20 * 1024 * 1024:
            fail(errors, f"file exceeds the 20 MiB public-release limit: {relative}")

        text = readable_text(path)
        if text is None or relative == Path("Scripts/validate_public_release.py"):
            continue

        for pattern in SECRET_PATTERNS.values():
            if pattern.search(text):
                fail(errors, f"credential pattern found in {relative}")
                break

    for plist_path in [
        ROOT / "StravaVault" / "Info.plist",
        ROOT / "StravaVault" / "PrivacyInfo.xcprivacy",
        ROOT / "AppStore" / "ExportOptions-app-store.plist.template",
    ]:
        try:
            with plist_path.open("rb") as handle:
                plistlib.load(handle)
        except Exception as exc:
            fail(errors, f"invalid property list {plist_path.relative_to(ROOT)}: {exc}")

    for json_path in ROOT.rglob("*.json"):
        if ".git" in json_path.parts:
            continue
        try:
            json.loads(json_path.read_text(encoding="utf-8"))
        except Exception as exc:
            fail(errors, f"invalid JSON {json_path.relative_to(ROOT)}: {exc}")

    workspace_path = (
        ROOT
        / "StravaVaultClean.xcodeproj"
        / "project.xcworkspace"
        / "contents.xcworkspacedata"
    )
    if workspace_path.exists():
        try:
            workspace = ET.parse(workspace_path).getroot()
            locations = {
                element.attrib.get("location")
                for element in workspace.findall("FileRef")
            }
            if "self:" not in locations:
                fail(errors, "Xcode workspace does not reference the project itself")
        except Exception as exc:
            fail(
                errors,
                f"invalid Xcode workspace {workspace_path.relative_to(ROOT)}: {exc}",
            )

    project_path = ROOT / "StravaVaultClean.xcodeproj" / "project.pbxproj"
    if project_path.exists():
        project_text = project_path.read_text(encoding="utf-8")
        swift_files = list((ROOT / "StravaVault").rglob("*.swift"))
        for swift_file in swift_files:
            if swift_file.name not in project_text:
                fail(
                    errors,
                    f"Swift source is not referenced by the shipping project: "
                    f"{swift_file.relative_to(ROOT)}",
                )

        if "ROUTE_VAULT_MAPBOX_PUBLIC_TOKEN = \"$(MAPBOX_PUBLIC_TOKEN)\";" not in project_text:
            fail(errors, "Mapbox token is not sourced from local configuration")
        if "ROUTE_VAULT_STRAVA_CLIENT_ID = \"$(STRAVA_CLIENT_ID)\";" not in project_text:
            fail(errors, "Strava client ID is not sourced from local configuration")
        if 'ROUTE_VAULT_STRAVA_CLIENT_SECRET = "";' not in project_text:
            fail(errors, "Release configuration does not explicitly clear the Strava client secret")

    privacy_path = ROOT / "StravaVault" / "PrivacyInfo.xcprivacy"
    if privacy_path.exists():
        with privacy_path.open("rb") as handle:
            privacy = plistlib.load(handle)
        collected = privacy.get("NSPrivacyCollectedDataTypes", [])
        if len(collected) < 6:
            fail(errors, "privacy manifest does not declare the audited collected data types")

    bootstrap_path = ROOT / "supabase" / "functions" / "account-bootstrap" / "index.ts"
    if bootstrap_path.exists():
        bootstrap_text = bootstrap_path.read_text(encoding="utf-8")
        if "https://www.strava.com/api/v3/athlete" not in bootstrap_text:
            fail(errors, "account bootstrap does not verify the athlete directly with Strava")
        if "payloadAthlete" in bootstrap_text:
            fail(errors, "account bootstrap still trusts a client-supplied athlete profile")

    if errors:
        print("Public release validation failed:")
        for error in errors:
            print(f"  - {error}")
        return 1

    tracked_files = sum(
        1 for path in ROOT.rglob("*") if path.is_file() and ".git" not in path.parts
    )
    print(f"Public release validation passed for {tracked_files} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

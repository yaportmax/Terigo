#!/usr/bin/env python3
"""Build and exercise the native app, retaining source-linked simulator evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys

BUILD = Path("build")


def prepare_simulator():
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
    ))["devices"]
    phones = [device for runtime, entries in devices.items() if ".iOS-" in runtime
              for device in entries if device["name"].startswith("iPhone")]
    if not phones:
        raise SystemExit("No available iPhone simulator")
    device = next((phone for phone in phones if phone["name"] == "iPhone 17 Pro"), phones[0])
    subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=False)
    subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True)
    subprocess.run(["xcrun", "simctl", "status_bar", device["udid"], "override",
                    "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100"], check=True)
    (BUILD / "simulator.json").write_text(json.dumps(device))
    return device


def run_phase(phase, device):
    command = ["xcodebuild", "build-for-testing" if phase == "build" else "test-without-building",
               "-project", "StravaVaultClean.xcodeproj", "-scheme", "StravaVault",
               "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={device['udid']}",
               "-derivedDataPath", "build/DerivedData", "CODE_SIGNING_ALLOWED=NO"]
    if phase == "test":
        command += ["-resultBundlePath", "build/Terigo.xcresult", "-parallel-testing-enabled", "NO",
                    "-maximum-concurrent-test-simulator-destinations", "1",
                    "-skip-testing:StravaVaultCleanUITests/StravaVaultCleanLaunchPerformanceTests"]
    print(" ".join(command), flush=True)
    with (BUILD / "xcodebuild.log").open("w" if phase == "build" else "a") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            log.write(line)
            if any(token in line for token in ("error:", "warning:", "Test Case", "Test Suite", "** ")):
                print(line, end="", flush=True)
        status = process.wait()
    (BUILD / "validation.json").write_text(json.dumps({
        "source_sha": os.environ.get("GITHUB_SHA") or subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True).strip(),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "device": device["name"], "phase": phase, "passed": phase == "test" and status == 0,
        "signed": False, "data": "synthetic UI test fixtures"
    }, indent=2) + "\n")
    return status


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "all"
    if phase not in {"all", "build", "test"}:
        raise SystemExit("Usage: validate_ios.py [all|build|test]")
    BUILD.mkdir(exist_ok=True)
    device = json.loads((BUILD / "simulator.json").read_text()) if phase == "test" else prepare_simulator()
    for selected in (["build", "test"] if phase == "all" else [phase]):
        status = run_phase(selected, device)
        if status:
            raise SystemExit(status)


if __name__ == "__main__":
    main()

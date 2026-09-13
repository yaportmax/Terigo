#!/usr/bin/env python3
"""Run Terigo's real iOS tests and retain source-linked simulator evidence."""
import json
import os
from pathlib import Path
import subprocess


def main():
    build = Path("build")
    build.mkdir(exist_ok=True)
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
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
    command = ["xcodebuild", "test", "-project", "StravaVaultClean.xcodeproj",
               "-scheme", "StravaVault", "-configuration", "Debug",
               "-destination", f"platform=iOS Simulator,id={device['udid']}",
               "-derivedDataPath", "build/DerivedData", "-resultBundlePath", "build/Terigo.xcresult",
               "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
               "-skip-testing:StravaVaultCleanUITests/StravaVaultCleanLaunchPerformanceTests",
               "CODE_SIGNING_ALLOWED=NO"]
    print(" ".join(command), flush=True)
    with (build / "xcodebuild.log").open("w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            log.write(line)
            if any(token in line for token in ("error:", "warning:", "Test Case", "Test Suite", "** TEST")):
                print(line, end="", flush=True)
        status = process.wait()
    (build / "validation.json").write_text(json.dumps({
        "source_sha": os.environ.get("GITHUB_SHA") or subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True).strip(),
        "xcode": xcode, "device": device["name"], "passed": status == 0,
        "signed": False, "data": "synthetic UI test fixtures"
    }, indent=2) + "\n")
    raise SystemExit(status)


if __name__ == "__main__":
    main()

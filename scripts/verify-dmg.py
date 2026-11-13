#!/usr/bin/env python3
"""
Mimra — DMG Verification Tool (conforming to the /premium-macos-dmg skill)
Mounts a macOS DMG read-only, verifies payload, checks /Applications symlink,
validates code signature, checks background assets, and safely detaches.
"""

import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def run_cmd(command, timeout=90):
    return subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def verify_dmg(dmg_path: Path):
    if sys.platform != "darwin":
        raise RuntimeError("DMG verification requires macOS")
    if not dmg_path.is_file():
        raise FileNotFoundError(f"DMG not found at: {dmg_path}")

    print(f"Verifying integrity of {dmg_path.name} via hdiutil verify...")
    v = run_cmd(["hdiutil", "verify", str(dmg_path)], timeout=180)
    if v.returncode != 0:
        raise RuntimeError(
            "hdiutil verify failed: " + v.stderr.decode(errors="replace")[-800:]
        )

    mounted = None
    results = {
        "dmg": str(dmg_path),
        "hdiutil_verify": "passed",
        "finder_visual_acceptance": "pending-manual-inspection",
    }

    try:
        print("Mounting DMG read-only...")
        attach = run_cmd(
            ["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(dmg_path)],
            timeout=90,
        )
        if attach.returncode != 0:
            raise RuntimeError(
                "hdiutil attach failed: " + attach.stderr.decode(errors="replace")[-800:]
            )

        record = plistlib.loads(attach.stdout)
        mountpoints = [
            x.get("mount-point")
            for x in record.get("system-entities", [])
            if x.get("mount-point")
        ]
        if not mountpoints:
            raise RuntimeError("DMG attached but no Finder mount point was returned")

        mounted = Path(mountpoints[0])
        print(f"Mounted volume at: {mounted}")

        apps = sorted(mounted.glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError(
                f"Expected exactly one .app bundle; found {[a.name for a in apps]}"
            )

        app_bundle = apps[0]
        results["app"] = app_bundle.name

        # Check /Applications symlink
        link = mounted / "Applications"
        if not link.is_symlink():
            raise RuntimeError("Applications entry in DMG is not a symlink")
        link_target = os.readlink(link)
        if link_target != "/Applications":
            raise RuntimeError(
                f"Applications symlink points to unexpected target: {link_target}"
            )
        results["applications_symlink"] = link_target

        # Check .DS_Store presence
        ds_store = mounted / ".DS_Store"
        results["has_ds_store"] = ds_store.is_file()

        # Check .background directory and image assets
        bg_dir = mounted / ".background"
        if bg_dir.is_dir():
            bg_files = [f.name for f in bg_dir.iterdir() if f.is_file()]
            results["background_directory"] = "present"
            results["background_files"] = bg_files
        else:
            results["background_directory"] = "missing"

        # Check Info.plist
        info_plist = app_bundle / "Contents" / "Info.plist"
        if not info_plist.is_file():
            raise RuntimeError(f"Application bundle missing Info.plist: {app_bundle}")
        with info_plist.open("rb") as f:
            meta = plistlib.load(f)

        results.update(
            {
                "bundle_id": meta.get("CFBundleIdentifier"),
                "version": meta.get("CFBundleShortVersionString"),
                "build_version": meta.get("CFBundleVersion"),
                "min_macos": meta.get("LSMinimumSystemVersion"),
            }
        )

        # Check codesign
        print("Validating code signature...")
        sign = run_cmd(
            ["codesign", "--verify", "--deep", "--strict", str(app_bundle)], timeout=40
        )
        results["codesign_verify"] = (
            "passed"
            if sign.returncode == 0
            else "failed-or-unsigned"
        )
        results["codesign_details"] = sign.stderr.decode(errors="replace")[-500:]

    finally:
        if mounted is not None:
            print("Detaching mounted volume...")
            detach = run_cmd(["hdiutil", "detach", str(mounted)], timeout=90)
            results["detached"] = detach.returncode == 0

    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", help="Path to DMG file")
    parser.add_argument(
        "--expected-version",
        dest="expected_version",
        help="Optional CFBundleShortVersionString assertion",
        default=None,
    )
    parser.add_argument(
        "--expected-build",
        dest="expected_build",
        help="Optional CFBundleVersion assertion",
        default=None,
    )
    args = parser.parse_args()

    dmg_path = Path(args.dmg).expanduser().resolve()
    try:
        report = verify_dmg(dmg_path)
        print("\n=== Verification Report ===")
        print(json.dumps(report, indent=2, ensure_ascii=False))

        if args.expected_version and report.get("version") != args.expected_version:
            raise ValueError(
                f"Version mismatch: expected '{args.expected_version}', got '{report.get('version')}'"
            )
        if args.expected_build and str(report.get("build_version")) != str(args.expected_build):
            raise ValueError(
                f"Build version mismatch: expected '{args.expected_build}', got '{report.get('build_version')}'"
            )

        if report.get("codesign_verify") == "failed-or-unsigned":
            print(
                "\nWARNING: Code signature check did not pass (may be unsigned local build).",
                file=sys.stderr,
            )
        return 0
    except Exception as e:
        print(f"\nERROR: Verification failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Bump the build number for one app target.

If project.yml exists in the current directory (an XcodeGen project), it is
treated as the source of truth: every `CURRENT_PROJECT_VERSION: "N"` line in
it is bumped by 1 (these projects keep all targets in lockstep, matching each
repo's own ship.sh), then `xcodegen generate` regenerates the .xcodeproj -
editing project.pbxproj directly for such a project would get silently
overwritten by the next `xcodegen generate` since project.yml wouldn't agree.

Otherwise, only the buildSettings block for the given bundle id in
project.pbxproj is bumped, leaving other targets (e.g. test bundles)
untouched.

Prints the new version number on success.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--xcodeproj", required=True, help="Path to the .xcodeproj directory")
parser.add_argument("--bundle-id", required=True, help="PRODUCT_BUNDLE_IDENTIFIER of the app target to bump")
args = parser.parse_args()

project_yml = Path("project.yml")

if project_yml.exists():
    text = project_yml.read_text()
    new_version = None

    def repl(m: re.Match) -> str:
        global new_version
        new_version = int(m.group(1)) + 1
        return f'CURRENT_PROJECT_VERSION: "{new_version}"'

    new_text, count = re.subn(r'CURRENT_PROJECT_VERSION: "(\d+)"', repl, text)
    if count == 0 or new_version is None:
        sys.exit("Could not find CURRENT_PROJECT_VERSION in project.yml")

    project_yml.write_text(new_text)
    result = subprocess.run(["xcodegen", "generate"], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.exit(f"xcodegen generate failed with exit code {result.returncode}")
    print(new_version)
else:
    pbxproj = Path(args.xcodeproj) / "project.pbxproj"
    text = pbxproj.read_text()
    new_version = None

    def bump(match: re.Match) -> str:
        global new_version
        block = match.group(0)
        if f"PRODUCT_BUNDLE_IDENTIFIER = {args.bundle_id};" not in block:
            return block

        def repl(m: re.Match) -> str:
            global new_version
            new_version = int(m.group(1)) + 1
            return f"CURRENT_PROJECT_VERSION = {new_version};"

        return re.sub(r"CURRENT_PROJECT_VERSION = (\d+);", repl, block)

    new_text, count = re.subn(r"\{[^{}]*\}", bump, text)
    if count == 0 or new_version is None:
        sys.exit(f"Could not find a buildSettings block for bundle id {args.bundle_id}")

    pbxproj.write_text(new_text)
    print(new_version)

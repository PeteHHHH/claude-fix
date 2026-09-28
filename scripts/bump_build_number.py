#!/usr/bin/env python3
"""Bump the build number (and optionally the marketing version) for one app target.

If project.yml exists in the current directory (an XcodeGen project), it is
treated as the source of truth: every `CURRENT_PROJECT_VERSION: "N"` line in
it is bumped by 1 (these projects keep all targets in lockstep, matching each
repo's own ship.sh), then `xcodegen generate` regenerates the .xcodeproj -
editing project.pbxproj directly for such a project would get silently
overwritten by the next `xcodegen generate` since project.yml wouldn't agree.

Otherwise, only the buildSettings block for the given bundle id in
project.pbxproj is bumped, leaving other targets (e.g. test bundles)
untouched.

Every real ship - both the /fix pipeline's own TestFlight upload and a manual
scripts/ship.sh run - passes --marketing-version so MARKETING_VERSION always
moves forward too (e.g. 2.01 -> 2.02), not just the internal build number
sitting invisibly in parentheses. Pass 'auto' to bump the last dot-component
(2.01 -> 2.02, preserving zero-padding), or 'major' to bump the leading
component and reset the rest to 0 (2.09 -> 3.0) - the caller decides which
based on how much changed. Output switches to `MARKETING_VERSION=<v>` /
`CURRENT_PROJECT_VERSION=<n>` lines whenever --marketing-version is passed;
omitting it prints just the bare new build number instead (kept only for
callers that genuinely want a build-number-only bump).
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--xcodeproj", required=True, help="Path to the .xcodeproj directory")
parser.add_argument("--bundle-id", required=True, help="PRODUCT_BUNDLE_IDENTIFIER of the app target to bump")
parser.add_argument(
    "--marketing-version",
    help="New MARKETING_VERSION, 'auto' to bump the last dot-component (e.g. 2.01 -> 2.02), "
    "or 'major' to bump the leading component and reset the rest (e.g. 2.09 -> 3.0). "
    "Omit to leave MARKETING_VERSION untouched.",
)
args = parser.parse_args()


def next_marketing_version(current: str) -> str:
    if args.marketing_version not in ("auto", "major"):
        return args.marketing_version
    major, dot, minor = current.rpartition(".")
    if not dot:
        # No dot component at all (e.g. a bare "3") - treat the whole
        # string as the major version with an implicit ".0".
        major, minor = current, "0"
    if args.marketing_version == "major":
        return f"{int(major) + 1}.0"
    # Zero-pad to the width of the existing minor component so "2.01" ->
    # "2.02" instead of dropping the leading zero to become "2.2".
    return f"{major}.{str(int(minor) + 1).zfill(len(minor))}"


project_yml = Path("project.yml")

if project_yml.exists():
    text = project_yml.read_text()
    new_build = None

    def bump_build(m: re.Match) -> str:
        global new_build
        new_build = int(m.group(1)) + 1
        return f'CURRENT_PROJECT_VERSION: "{new_build}"'

    text, count = re.subn(r'CURRENT_PROJECT_VERSION: "(\d+)"', bump_build, text)
    if count == 0 or new_build is None:
        sys.exit("Could not find CURRENT_PROJECT_VERSION in project.yml")

    new_marketing = None
    if args.marketing_version:
        current_match = re.search(r'MARKETING_VERSION: "([0-9.]+)"', text)
        if not current_match:
            sys.exit("Could not find MARKETING_VERSION in project.yml")
        new_marketing = next_marketing_version(current_match.group(1))
        text = re.sub(r'MARKETING_VERSION: "[0-9.]+"', f'MARKETING_VERSION: "{new_marketing}"', text)

    project_yml.write_text(text)
    result = subprocess.run(["xcodegen", "generate"], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.exit(f"xcodegen generate failed with exit code {result.returncode}")

    if args.marketing_version:
        print(f"MARKETING_VERSION={new_marketing}")
        print(f"CURRENT_PROJECT_VERSION={new_build}")
    else:
        print(new_build)
else:
    pbxproj = Path(args.xcodeproj) / "project.pbxproj"
    text = pbxproj.read_text()
    new_build = None
    new_marketing = None

    def bump_block(match: re.Match) -> str:
        global new_build, new_marketing
        block = match.group(0)
        if f"PRODUCT_BUNDLE_IDENTIFIER = {args.bundle_id};" not in block:
            return block

        def bump_build_repl(m: re.Match) -> str:
            global new_build
            new_build = int(m.group(1)) + 1
            return f"CURRENT_PROJECT_VERSION = {new_build};"

        block = re.sub(r"CURRENT_PROJECT_VERSION = (\d+);", bump_build_repl, block)

        if args.marketing_version:
            current_match = re.search(r"MARKETING_VERSION = ([0-9.]+);", block)
            if not current_match:
                sys.exit(f"Could not find MARKETING_VERSION in the buildSettings block for {args.bundle_id}")
            new_marketing = next_marketing_version(current_match.group(1))
            block = re.sub(r"MARKETING_VERSION = [0-9.]+;", f"MARKETING_VERSION = {new_marketing};", block)

        return block

    new_text, count = re.subn(r"\{[^{}]*\}", bump_block, text)
    if count == 0 or new_build is None:
        sys.exit(f"Could not find a buildSettings block for bundle id {args.bundle_id}")

    pbxproj.write_text(new_text)

    if args.marketing_version:
        print(f"MARKETING_VERSION={new_marketing}")
        print(f"CURRENT_PROJECT_VERSION={new_build}")
    else:
        print(new_build)

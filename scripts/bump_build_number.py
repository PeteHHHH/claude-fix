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

With no --marketing-version, prints just the new build number (this is the
claude-fix pipeline's own bump-on-every-merge behavior - callers there parse
a single bare value, so this default output is load-bearing and must not
change). Pass --marketing-version to also bump/set MARKETING_VERSION - used
by scripts/ship.sh for an actual release, never by the /fix pipeline - which
switches the output to `MARKETING_VERSION=<v>` / `CURRENT_PROJECT_VERSION=<n>`
lines instead.
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
    help="New MARKETING_VERSION, or 'auto' to bump the last dot-component (e.g. 1.0 -> 1.1). "
    "Omit to leave MARKETING_VERSION untouched (the /fix pipeline's build-number-only behavior).",
)
args = parser.parse_args()


def next_marketing_version(current: str) -> str:
    if args.marketing_version != "auto":
        return args.marketing_version
    major, _, minor = current.rpartition(".")
    return f"{major}.{int(minor) + 1}"


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

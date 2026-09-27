#!/usr/bin/env python3
"""Bump CURRENT_PROJECT_VERSION for one app target in project.pbxproj.

Only touches buildSettings blocks that belong to the given bundle id, leaving
other targets (e.g. test bundles) untouched. Prints the new version number on
success.
"""
import argparse
import re
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--xcodeproj", required=True, help="Path to the .xcodeproj directory")
parser.add_argument("--bundle-id", required=True, help="PRODUCT_BUNDLE_IDENTIFIER of the app target to bump")
args = parser.parse_args()

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

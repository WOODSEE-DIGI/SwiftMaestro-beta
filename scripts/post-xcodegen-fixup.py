#!/usr/bin/env python3
"""
Post-xcodegen fixup: remove PBXFileReference folder references for vendored
SPM packages from the generated project.pbxproj.

Why: xcodegen's `packages:` section generates BOTH XCLocalSwiftPackageReference
(correct SPM references) AND PBXFileReference folder entries in the project
navigator. Xcode sees the folder entries and tries to open the vendored
packages as Xcode projects instead of SPM packages, causing "Missing package
product" errors and "Couldn't load project" failures.

This script removes the folder references, keeping only the SPM references.
Each folder-ref UUID appears twice in project.pbxproj — once as the
PBXFileReference and once in the parent PBXGroup's `children` list — so BOTH
lines must be removed or the project is left with dangling references.

Only `Vendor/` paths are touched. `Sources/Resources/Plugins` is an intentional
folder reference (bundled WKWebView plugins) and must never be removed.

Run via scripts/gen-project.sh (not wired to an xcodegen post-gen hook —
xcodegen has none configured).
"""

import os
import re
import sys


def main():
    # Script lives in <repo>/scripts/, so the repo root is one level up.
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pbxproj_path = os.path.join(repo_root, 'SwiftMaestro.xcodeproj', 'project.pbxproj')

    if not os.path.exists(pbxproj_path):
        print(f"Warning: {pbxproj_path} not found", file=sys.stderr)
        return 1

    with open(pbxproj_path, 'r') as f:
        lines = f.readlines()

    # Pass 1: collect UUIDs of Vendor folder PBXFileReferences.
    fileref_re = re.compile(
        r'^\s*([A-F0-9]{24}) /\* .+ \*/ = \{isa = PBXFileReference; '
        r'.*lastKnownFileType = folder;.*path = ("?)Vendor/')
    folder_uuids = set()
    for line in lines:
        m = fileref_re.match(line)
        if m:
            folder_uuids.add(m.group(1))

    if not folder_uuids:
        return 0

    # Pass 2: drop the PBXFileReference lines AND the matching children entries.
    child_re = re.compile(r'^\s*([A-F0-9]{24}) /\* .+ \*/,\s*$')
    filtered = []
    removed_refs = 0
    removed_children = 0
    for line in lines:
        m = fileref_re.match(line)
        if m:
            removed_refs += 1
            continue
        cm = child_re.match(line)
        if cm and cm.group(1) in folder_uuids:
            removed_children += 1
            continue
        filtered.append(line)

    if removed_refs != removed_children:
        print(f"Warning: removed {removed_refs} folder references but "
              f"{removed_children} group children — project may be inconsistent",
              file=sys.stderr)

    with open(pbxproj_path, 'w') as f:
        f.writelines(filtered)

    print(f"Post-gen: removed {removed_refs} vendored-package folder references "
          f"(+{removed_children} group children)")
    return 0


if __name__ == '__main__':
    sys.exit(main())

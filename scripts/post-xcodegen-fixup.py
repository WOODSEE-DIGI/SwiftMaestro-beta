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
Run automatically by `xcodegen generate` via the post-gen hook.
"""

import re
import sys
import os

def main():
    project_dir = os.path.dirname(os.path.abspath(__file__))
    pbxproj_path = os.path.join(project_dir, 'SwiftMaestro.xcodeproj', 'project.pbxproj')

    if not os.path.exists(pbxproj_path):
        print(f"Warning: {pbxproj_path} not found")
        return

    with open(pbxproj_path, 'r') as f:
        lines = f.readlines()

    # Remove PBXFileReference entries that are folder references to Vendor packages
    filtered = []
    removed = 0
    for line in lines:
        if ('PBXFileReference' in line
            and 'Vendor/' in line
            and 'lastKnownFileType = folder' in line):
            removed += 1
            continue
        filtered.append(line)

    with open(pbxproj_path, 'w') as f:
        f.writelines(filtered)

    if removed > 0:
        print(f"Post-gen: removed {removed} folder references for vendored SPM packages")

if __name__ == '__main__':
    main()

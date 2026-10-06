#!/usr/bin/env python3
"""Update the 'What's New in X.Y.Z' section of README.md from CHANGELOG.md."""
import re
import sys


def main() -> int:
    if len(sys.argv) < 4:
        print("Usage: update-readme-whatsnew.py <version> <README.md> <CHANGELOG.md>", file=sys.stderr)
        return 1

    version = sys.argv[1]
    readme_path = sys.argv[2]
    changelog_path = sys.argv[3]

    with open(changelog_path, "r", encoding="utf-8") as f:
        changelog = f.read()

    # Extract the body of the requested CHANGELOG section (everything between its
    # heading and the next top-level '# SwiftMaestro ' heading or EOF).
    section_pattern = re.compile(
        rf"^# SwiftMaestro {re.escape(version)}\s*\n"
        r"(.*?)(?=\n^# SwiftMaestro |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = section_pattern.search(changelog)
    if not match:
        print(f"WARNING: no CHANGELOG section found for {version}; README not updated", file=sys.stderr)
        return 0

    section_body = match.group(1).strip()

    # Demote CHANGELOG headings by one level so they nest under the README's
    # "What's New" H2 instead of becoming sibling H2 sections.
    section_body = re.sub(r"^(#{1,5}) ", r"#\1 ", section_body, flags=re.MULTILINE)

    with open(readme_path, "r", encoding="utf-8") as f:
        readme = f.read()

    new_section = (
        f"## What's New in {version}\n\n"
        f"{section_body}\n\n"
        "See [CHANGELOG.md](CHANGELOG.md) for earlier releases.\n"
    )

    # Replace the existing "What's New" section, from its heading up to (but not
    # including) the next top-level Markdown heading.
    updated_readme = re.sub(
        r"## What'?s New in .*?(?=\n^## |\Z)",
        new_section,
        readme,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )

    if updated_readme == readme:
        print("WARNING: README.md already up to date or no 'What\'s New' section found", file=sys.stderr)
        return 0

    with open(readme_path, "w", encoding="utf-8") as f:
        f.write(updated_readme)

    print(f"Updated README.md 'What's New' section to {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

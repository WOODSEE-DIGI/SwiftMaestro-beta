#!/usr/bin/env python3
"""Update swiftmaestro.com/download.html with the latest release notes,
checksums, sizes, and version strings from a SwiftMaestro release.

Usage:
    python3 update-website-release-notes.py <version> <website_dir> [<dist_dir>] [<changelog>]

Example:
    python3 update-website-release-notes.py 0.6.4 \
        ~/GitHub/FUSV/Websites/swiftmaestro-site \
        ~/GitHub/FUSV/SwiftMaestro/dist \
        ~/GitHub/FUSV/SwiftMaestro/CHANGELOG.md
"""

import hashlib
import html
import os
import re
import sys


def human_size(num_bytes: int) -> str:
    gb = num_bytes / (1024 ** 3)
    return f"{gb:.0f}&nbsp;GB" if gb >= 1 else f"{num_bytes / (1024 ** 2):.0f}&nbsp;MB"


def format_number(num: int) -> str:
    return f"{num:,}"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def extract_top_changelog_section(path: str, version: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    # Match from "# SwiftMaestro X.Y.Z" up to (but not including) the next "# SwiftMaestro"
    pattern = re.compile(
        rf"^#\s+SwiftMaestro\s+{re.escape(version)}\s*\n(.*?)(?=^#\s+SwiftMaestro\s)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f"No CHANGELOG section found for version {version}")
    return m.group(1).strip()


def markdown_bullet_to_html(line: str) -> str | None:
    """Convert a single '- **Title**: description' bullet to an <li>."""
    m = re.match(r"^-\s+\*\*(.+?)\*\*:\s*(.*)$", line)
    if not m:
        return None
    title = m.group(1).strip()
    desc = m.group(2).strip()

    # Convert inline `code` markers and bold, then escape HTML.
    def inline_md_to_html(text: str) -> str:
        # Bold
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        # Code
        text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
        # Escape remaining characters
        text = html.escape(text)
        # Restore tags we just inserted (html.escape clobbers them)
        text = text.replace("&lt;strong&gt;", "<strong>").replace("&lt;/strong&gt;", "</strong>")
        text = text.replace("&lt;code&gt;", "<code>").replace("&lt;/code&gt;", "</code>")
        return text

    title_html = inline_md_to_html(title)
    desc_html = inline_md_to_html(desc)
    return f'<li><strong>{title_html}</strong> — {desc_html}</li>'


def changelog_to_html_list(section: str) -> str:
    items = []
    for line in section.splitlines():
        line = line.strip()
        if not line or line.startswith("##"):
            # Skip section headings to match the existing site style.
            continue
        item = markdown_bullet_to_html(line)
        if item:
            items.append("            " + item)
    return "\n".join(items)


def update_version_strings(page: str, version: str) -> str:
    page = re.sub(
        r'(<span id="download-version">)v\d+\.\d+\.\d+(</span>)',
        rf"\1v{version}\2",
        page,
    )
    page = re.sub(
        r'(SwiftMaestro\s+)v\d+\.\d+\.\d+(\s+—\s+Requires)',
        rf"\1v{version}\2",
        page,
    )
    return page


def update_checksums_and_links(
    page: str,
    version: str,
    full_hash: str,
    light_hash: str,
    full_size: int,
    light_size: int,
) -> str:
    # Replace the entire <pre> checksum block.
    page = re.sub(
        r"<pre[^>]*>\s*<code>shasum.*?# Light:.*?</code>\s*</pre>",
        (
            f"<pre style=\"background:var(--surface);padding:0.8rem 1rem;border-radius:8px;overflow-x:auto;font-size:0.85rem;\"><code>shasum -a 256 ~/Downloads/SwiftMaestro-{version}-full.pkg\n"
            f"# Full:  {full_hash}\n"
            f"shasum -a 256 ~/Downloads/SwiftMaestro-{version}-light.pkg\n"
            f"# Light: {light_hash}</code></pre>"
        ),
        page,
        flags=re.DOTALL,
    )

    # Expected sizes paragraph.
    page = re.sub(
        r"Expected sizes: Full <strong>[^<]+</strong>\s*·\s*Light <strong>[^<]+</strong>",
        (
            f"Expected sizes: Full <strong>{format_number(full_size)} bytes ({human_size(full_size)})</strong> · "
            f"Light <strong>{format_number(light_size)} bytes ({human_size(light_size)})</strong>"
        ),
        page,
    )

    # Direct .pkg links.
    page = re.sub(
        r'<a href="https://s3\.ap-southeast-2\.onidel\.cloud/swiftmaestro-releases/SwiftMaestro-\d+\.\d+\.\d+-full\.pkg">Direct Full \.pkg</a>\s*·\s*'
        r'<a href="https://s3\.ap-southeast-2\.onidel\.cloud/swiftmaestro-releases/SwiftMaestro-\d+\.\d+\.\d+-light\.pkg">Direct Light \.pkg</a>',
        (
            f'<a href="https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/SwiftMaestro-{version}-full.pkg">Direct Full .pkg</a> · '
            f'<a href="https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/SwiftMaestro-{version}-light.pkg">Direct Light .pkg</a>'
        ),
        page,
    )

    return page


def update_release_notes_section(page: str, version: str, html_list: str) -> str:
    section_pattern = re.compile(
        r'(<div class="download-detail">\s*<h3>What\'s new in )v(\d+\.\d+\.\d+)(</h3>\s*<ul class="check-list">)(.*?)(</ul>\s*</div>)',
        re.DOTALL,
    )

    m = section_pattern.search(page)
    if not m:
        raise RuntimeError("Could not find an existing 'What\'s new in' section in download.html")

    existing_version = m.group(2)
    new_section = (
        f'<div class="download-detail">\n'
        f'          <h3>What\'s new in v{version}</h3>\n'
        f'          <ul class="check-list">\n'
        f'{html_list}\n'
        f'          </ul>\n'
        f'        </div>\n\n'
    )

    if existing_version == version:
        # Replace the content of the first section's <ul>.
        return (
            page[: m.start(4)]
            + "\n"
            + html_list
            + "\n          "
            + page[m.start(5) :]
        )

    # Insert a new section before the first existing one.
    return page[: m.start()] + new_section + page[m.start() :]


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 1

    version = sys.argv[1]
    website_dir = sys.argv[2]
    dist_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.getcwd(), "dist")
    changelog = sys.argv[4] if len(sys.argv) > 4 else os.path.join(os.getcwd(), "CHANGELOG.md")

    download_html = os.path.join(website_dir, "download.html")
    full_pkg = os.path.join(dist_dir, f"SwiftMaestro-{version}-full.pkg")
    light_pkg = os.path.join(dist_dir, f"SwiftMaestro-{version}-light.pkg")

    for path in (download_html, full_pkg, light_pkg, changelog):
        if not os.path.exists(path):
            print(f"ERROR: missing {path}", file=sys.stderr)
            return 1

    section = extract_top_changelog_section(changelog, version)
    html_list = changelog_to_html_list(section)

    full_hash = sha256_file(full_pkg)
    light_hash = sha256_file(light_pkg)
    full_size = os.path.getsize(full_pkg)
    light_size = os.path.getsize(light_pkg)

    with open(download_html, "r", encoding="utf-8") as f:
        page = f.read()

    page = update_version_strings(page, version)
    page = update_checksums_and_links(page, version, full_hash, light_hash, full_size, light_size)
    page = update_release_notes_section(page, version, html_list)

    with open(download_html, "w", encoding="utf-8") as f:
        f.write(page)

    print(f"Updated {download_html} for v{version}")
    print(f"  Full: {full_size} bytes, sha256 {full_hash}")
    print(f"  Light: {light_size} bytes, sha256 {light_hash}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

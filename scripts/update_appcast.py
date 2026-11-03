#!/usr/bin/env python3
"""Prepend a new <item> to docs/appcast.xml for a release.

Run by the release workflow after sign_update produces the EdDSA signature; it
automates the hand-edit documented in the release skill (step 5b). Release notes
are read from the NOTES env var (Markdown: an optional heading, then bullet
lines) and converted to the HTML list Sparkle shows in its update dialog.

Self-test for the notes conversion: python3 -m doctest scripts/update_appcast.py
"""
import argparse
import html
import os
import re
import sys
import time

DOCS = os.path.join(os.path.dirname(__file__), "..", "docs")
ANCHOR = "<language>en</language>\n"


def notes_to_html(md: str) -> str:
    r"""Convert Markdown release notes to the <ul> Sparkle shows.

    Heading lines are dropped (the GitHub release body keeps them), every
    remaining non-empty line becomes one <li>, and **bold** / `code` become
    <strong> / <code>. No other Markdown is converted.

    >>> print(notes_to_html("### Changes\n- **Fixes `claude` hanging** at launch"))
    <ul><li><strong>Fixes <code>claude</code> hanging</strong> at launch</li></ul>
    >>> print(notes_to_html('* Shows "< 1%" & no longer rounds to 0'))
    <ul><li>Shows &quot;&lt; 1%&quot; &amp; no longer rounds to 0</li></ul>
    """
    items = []
    for raw in md.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        for prefix in ("- ", "* ", "• "):
            if line.startswith(prefix):
                line = line[len(prefix):]
                break
        # Escape before adding tags, so the tags themselves aren't escaped.
        line = html.escape(line)
        line = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", line)
        line = re.sub(r"`([^`]+)`", r"<code>\1</code>", line)
        items.append(f"<li>{line}</li>")
    if not items:
        return ""
    return "<ul>" + "".join(items) + "</ul>"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)   # X.Y.Z (CFBundleShortVersion)
    ap.add_argument("--build", required=True)     # N     (CFBundleVersion / +N)
    ap.add_argument("--edsig", required=True)
    ap.add_argument("--length", required=True)
    # Appcast file to prepend to (appcast.xml = stable, appcast-beta.xml = beta).
    ap.add_argument("--appcast", default="appcast.xml")
    # Release tag the asset lives under; differs from the version for betas
    # (e.g. v1.5.6-beta.14 while the asset is still ClaudeBar-1.5.6.zip).
    ap.add_argument("--tag", default=None)
    args = ap.parse_args()

    appcast_path = os.path.join(DOCS, os.path.basename(args.appcast))
    tag = args.tag or f"v{args.version}"

    notes_html = notes_to_html(os.environ.get("NOTES", ""))
    if not notes_html:
        print("error: NOTES env produced no list items", file=sys.stderr)
        return 1

    with open(appcast_path, encoding="utf-8") as f:
        content = f.read()

    # Title carries the full tag (minus the leading "v") so beta builds that
    # share an X.Y.Z — e.g. 1.5.6-beta.14 and 1.5.6-beta.15 — stay distinct and
    # the idempotency check below doesn't collapse them.
    title_version = tag[1:] if tag.startswith("v") else tag

    if f"<title>Version {title_version}</title>" in content:
        print(f"note: {args.appcast} already lists {title_version}; leaving unchanged")
        return 0

    idx = content.find(ANCHOR)
    if idx == -1:
        print("error: <language>en</language> anchor not found in appcast",
              file=sys.stderr)
        return 1

    pub_date = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
    item = (
        "    <item>\n"
        f"      <title>Version {title_version}</title>\n"
        f"      <sparkle:version>{args.build}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>10.15.0</sparkle:minimumSystemVersion>\n"
        f"      <description><![CDATA[ {notes_html} ]]></description>\n"
        f"      <pubDate>{pub_date}</pubDate>\n"
        "      <enclosure\n"
        f"        url=\"https://github.com/beerbeatbox/claudebar/releases/download/{tag}/ClaudeBar-{args.version}.zip\"\n"
        "        sparkle:os=\"macos\"\n"
        f"        sparkle:edSignature=\"{args.edsig}\"\n"
        f"        length=\"{args.length}\"\n"
        "        type=\"application/octet-stream\" />\n"
        "    </item>\n"
    )

    insert_at = idx + len(ANCHOR)
    new = content[:insert_at] + item + content[insert_at:]
    with open(appcast_path, "w", encoding="utf-8") as f:
        f.write(new)
    print(f"Added {title_version} (build {args.build}) to {args.appcast}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

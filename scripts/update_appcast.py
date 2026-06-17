#!/usr/bin/env python3
"""Prepend a new <item> to docs/appcast.xml for a release.

Run by the release workflow after sign_update produces the EdDSA signature; it
automates the hand-edit documented in the release skill (step 5b). Release notes
are read from the NOTES env var (Markdown bullet lines) and converted to the
HTML list Sparkle shows in its update dialog.
"""
import argparse
import html
import os
import sys
import time

APPCAST = os.path.join(os.path.dirname(__file__), "..", "docs", "appcast.xml")
ANCHOR = "<language>en</language>\n"


def notes_to_html(md: str) -> str:
    items = []
    for raw in md.splitlines():
        line = raw.strip()
        if not line:
            continue
        for prefix in ("- ", "* ", "• "):
            if line.startswith(prefix):
                line = line[len(prefix):]
                break
        items.append(f"<li>{html.escape(line)}</li>")
    if not items:
        return ""
    return "<ul>" + "".join(items) + "</ul>"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)   # X.Y.Z (CFBundleShortVersion)
    ap.add_argument("--build", required=True)     # N     (CFBundleVersion / +N)
    ap.add_argument("--edsig", required=True)
    ap.add_argument("--length", required=True)
    args = ap.parse_args()

    notes_html = notes_to_html(os.environ.get("NOTES", ""))
    if not notes_html:
        print("error: NOTES env produced no list items", file=sys.stderr)
        return 1

    with open(APPCAST, encoding="utf-8") as f:
        content = f.read()

    if f"<title>Version {args.version}</title>" in content:
        print(f"note: appcast already lists v{args.version}; leaving unchanged")
        return 0

    idx = content.find(ANCHOR)
    if idx == -1:
        print("error: <language>en</language> anchor not found in appcast",
              file=sys.stderr)
        return 1

    pub_date = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
    item = (
        "    <item>\n"
        f"      <title>Version {args.version}</title>\n"
        f"      <sparkle:version>{args.build}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>10.15.0</sparkle:minimumSystemVersion>\n"
        f"      <description><![CDATA[ {notes_html} ]]></description>\n"
        f"      <pubDate>{pub_date}</pubDate>\n"
        "      <enclosure\n"
        f"        url=\"https://github.com/beerbeatbox/claudebar/releases/download/v{args.version}/ClaudeBar-{args.version}.zip\"\n"
        "        sparkle:os=\"macos\"\n"
        f"        sparkle:edSignature=\"{args.edsig}\"\n"
        f"        length=\"{args.length}\"\n"
        "        type=\"application/octet-stream\" />\n"
        "    </item>\n"
    )

    insert_at = idx + len(ANCHOR)
    new = content[:insert_at] + item + content[insert_at:]
    with open(APPCAST, "w", encoding="utf-8") as f:
        f.write(new)
    print(f"Added appcast item for v{args.version} (build {args.build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

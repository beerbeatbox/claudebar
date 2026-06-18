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

DOCS = os.path.join(os.path.dirname(__file__), "..", "docs")
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

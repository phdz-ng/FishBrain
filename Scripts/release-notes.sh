#!/bin/bash
# Prints the GitHub release notes for a version: the download link and checksum first, then how to
# open the unsigned app, then the changelog section.
#
#   Scripts/release-notes.sh 1.0 <sha256-of-the-dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: release-notes.sh <version> <sha256>}"
sha="${2:?usage: release-notes.sh <version> <sha256>}"

grep -q "^## $version\$" CHANGELOG.md || { echo "error: CHANGELOG.md has no '## $version' section" >&2; exit 1; }

cat <<EOF
## Download

**[Download FishBrain-unsigned.dmg](https://github.com/phdz-ng/FishBrain/releases/download/v$version/FishBrain-unsigned.dmg)**
(macOS 14 or later, Apple silicon and Intel)

SHA-256: \`$sha\`

EOF

cat docs/opening-an-unsigned-app.md

printf '\n## What is new in %s\n\n' "$version"
awk -v v="$version" '$0 == "## " v {f=1; next} /^## / {f=0} f' CHANGELOG.md

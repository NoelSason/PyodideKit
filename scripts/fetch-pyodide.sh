#!/usr/bin/env bash
#
# fetch-pyodide.sh — download the Pyodide runtime and stage the files an app
# needs to bundle. Nothing this script produces is committed to this repo: the
# runtime is upstream's to distribute, it is large, and pinning a copy here
# would go stale. See THIRD_PARTY_NOTICES.md.
#
# Usage:
#   scripts/fetch-pyodide.sh [--version 0.26.2] [--out Runtime] [--packages "numpy,pandas"]
#
# The output directory is what you drag into Xcode as a *folder reference*
# (blue folder), named `Pyodide`. A folder reference preserves the directory at
# runtime; a group (yellow folder) flattens it, which PyodideKit tolerates but
# which makes the bundle messier than it needs to be.

set -euo pipefail

VERSION="0.26.2"
OUT_DIR="Runtime"
# Core runtime plus the scientific stack most apps want. Trim it: every wheel
# here is bytes in someone's app download.
PACKAGES="numpy,pandas,matplotlib,matplotlib-pyodide,micropip,packaging,pillow,pyparsing,cycler,fonttools,kiwisolver,python-dateutil,pytz,six"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    --packages) PACKAGES="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ABS="$REPO_ROOT/$OUT_DIR"
CHECKSUMS="$REPO_ROOT/scripts/pyodide-checksums.txt"

TARBALL="pyodide-${VERSION}.tar.bz2"
URL="https://github.com/pyodide/pyodide/releases/download/${VERSION}/${TARBALL}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading Pyodide ${VERSION}"
echo "    ${URL}"
curl --fail --location --progress-bar --output "$WORK/$TARBALL" "$URL"

echo "==> Verifying"
ACTUAL="$(shasum -a 256 "$WORK/$TARBALL" | awk '{print $1}')"
EXPECTED="$(grep -E "^${VERSION}[[:space:]]" "$CHECKSUMS" 2>/dev/null | awk '{print $2}' || true)"

if [[ -z "$EXPECTED" ]]; then
  echo "    No pinned checksum for ${VERSION}."
  echo "    sha256: ${ACTUAL}"
  echo "    Add this line to scripts/pyodide-checksums.txt to pin it:"
  echo ""
  echo "        ${VERSION}  ${ACTUAL}"
  echo ""
elif [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "!!  Checksum mismatch for ${TARBALL}" >&2
  echo "    expected ${EXPECTED}" >&2
  echo "    actual   ${ACTUAL}" >&2
  exit 1
else
  echo "    sha256 OK (${ACTUAL})"
fi

echo "==> Extracting"
tar -xjf "$WORK/$TARBALL" -C "$WORK"
SRC="$WORK/pyodide"
[[ -d "$SRC" ]] || { echo "unexpected archive layout" >&2; exit 1; }

rm -rf "$OUT_ABS"
mkdir -p "$OUT_ABS"

echo "==> Staging core runtime"
for file in pyodide.js pyodide.asm.js pyodide.asm.wasm pyodide-lock.json python_stdlib.zip; do
  if [[ -f "$SRC/$file" ]]; then
    cp "$SRC/$file" "$OUT_ABS/"
  else
    echo "!!  missing core file: $file" >&2
    exit 1
  fi
done
# Newer releases ship an extra ES-module entry point; copy it when present.
[[ -f "$SRC/pyodide.mjs" ]] && cp "$SRC/pyodide.mjs" "$OUT_ABS/"

echo "==> Staging packages"
IFS=',' read -r -a WANTED <<< "$PACKAGES"
for package in "${WANTED[@]}"; do
  package="$(echo "$package" | xargs)"           # trim
  normalized="${package//-/_}"
  found=0
  for wheel in "$SRC/${normalized}"-*.whl "$SRC/${package}"-*.whl; do
    [[ -e "$wheel" ]] || continue
    cp "$wheel" "$OUT_ABS/"
    echo "    $(basename "$wheel")"
    found=1
    break
  done
  if [[ $found -eq 0 ]]; then
    echo "!!  no wheel found for '${package}' in Pyodide ${VERSION}" >&2
  fi
done

TOTAL="$(du -sh "$OUT_ABS" | awk '{print $1}')"
echo ""
echo "==> Done. ${TOTAL} in ${OUT_DIR}/"
echo ""
echo "Next:"
echo "  1. Drag ${OUT_DIR}/ into Xcode as a folder reference and rename it 'Pyodide'."
echo "  2. Confirm it is in Target > Build Phases > Copy Bundle Resources."
echo "  3. For On-Demand Resources, tag the folder 'python-runtime' and use"
echo "     .onDemandResource(tag: \"python-runtime\") as the asset source."

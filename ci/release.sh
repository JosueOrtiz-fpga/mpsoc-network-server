#!/usr/bin/env bash
# ci/release.sh - build, test and collect a tagged release (make release).
#
# Refuses to run unless the checkout is clean (no local changes, no untracked files)
# and HEAD carries the release tag. Builds in a clean worktree of the tag under
# build/release/<tag>/, runs the full build and the HIL suite there, and on a pass
# collects the artifacts into $HIL_RELEASES/<tag>/, which is never overwritten.
# The Yocto caches outside the checkout (sw/Makefile, YOCTO_CACHE) keep the clean
# build incremental.
#
#   <tag>/  BOOT.BIN  zub1cg-sd.wic  Image  system.dtb  rootfs.tar.gz  jtag/
#           pl/<stem>.bit.bin .dtbo .dtso   <stem>.xsa   sdk/ (RELEASE_SDK=1)
#           hil/ (junit.xml, console.log, jtag-boot.log, commands.log)
#           manifest.txt  layers.lock.yml  RELEASE_NOTES.md  release.log  SHA256SUMS
#
# Needs Vivado's settings64.sh in the environment (vivado, xsdb, bootgen), docker
# for kas-container, and the HIL bench (make hil).
#
# Usage: ci/release.sh [tag]      (default: the v* tag on HEAD)
# Env:   RELEASE_SDK=1            also build and collect the SDK (hours on a cold cache;
#                                 off by default, the SDK can be built separately)
#        RELEASE_KEEP=1           keep the worktree after a successful release
#        (a failed release always keeps it, for the logs)
set -euo pipefail

die() { echo "release: ERROR: $*" >&2; exit 1; }
say() { echo "release: $*"; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../tests/hil/scripts/hil.env
. "$root/tests/hil/scripts/hil.env"
cd "$root"

# ---- refuse early ---------------------------------------------------------------------
[ $# -le 1 ] || die "usage: $0 [tag]"
tag=${1:-$(git describe --exact-match --tags --match 'v*' HEAD 2>/dev/null || true)}
[ -n "$tag" ] || die "HEAD carries no release tag (v*): tag it first, e.g. git tag -a v0.2.0"
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$tag' is not a release tag (vMAJOR.MINOR.PATCH)"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no tag $tag"
[ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)" ] || die "HEAD is not $tag"
if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  die "local changes or untracked files: a release builds the tag, commit or remove them"
fi

dest="$HIL_RELEASES/$tag"
[ -d "$HIL_RELEASES" ] && [ -w "$HIL_RELEASES" ] \
  || die "$HIL_RELEASES missing or not writable (run tests/hil/scripts/setup-host.sh)"
[ ! -e "$dest" ] || die "$dest exists: releases are never overwritten (tag a v*.*.x fix instead)"
for t in vivado xsdb bootgen; do
  command -v "$t" >/dev/null || die "$t not on PATH: source <Vivado install>/settings64.sh first"
done
command -v kas-container >/dev/null || die "kas-container not found"

# ---- clean worktree of the tag ----------------------------------------------------------
wt="$root/build/release/$tag"
if [ -e "$wt" ]; then
  say "removing the worktree of an earlier attempt: $wt"
  git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  git worktree prune
fi
mkdir -p "$(dirname "$wt")"
git worktree add --detach "$wt" "$tag"

log="$wt/release.log"
say "building $tag in $wt (full log: $log)"
start=$(date -u +%s)
# One && chain: set -e does not apply inside a command whose status || tests.
sdk_on=${RELEASE_SDK:-0}
build="make -C $wt hw-lint hw-sim hw-xsa hw-plpkg platform-check sw-image"
if [ "$sdk_on" = 1 ]; then build+=" sw-sdk"; fi
hil="make -C $wt hil"
{ echo "+ $build" && $build && echo "+ $hil" && $hil; } > >(tee "$log") 2>&1 \
  || die "build or HIL suite failed; the worktree and $log stay for inspection"

# ---- collect ----------------------------------------------------------------------------
say "collecting into $dest"
stage="$HIL_RELEASES/.$tag.partial"
rm -rf "$stage"
mkdir -p "$stage/pl" "$stage/hil"

sw="$wt/out/sw"
cp -a "$sw/BOOT.BIN" "$sw/zub1cg-sd.wic" "$sw/Image" "$sw/system.dtb" "$sw/rootfs.tar.gz" \
      "$sw/jtag" "$sw/manifest.txt" "$sw/layers.lock.yml" "$stage/"

stem=$(cat "$wt/out/hw/pl/current")
cp -a "$wt/out/hw/pl/$stem".{bit.bin,dtbo,dtso} "$stage/pl/"
cp -a "$wt/out/hw/$stem.xsa" "$stage/"

if [ "$sdk_on" = 1 ]; then
  mapfile -t sdk < <(find "$wt/build/yocto" -path '*/deploy/sdk/*.sh' -type f)
  [ ${#sdk[@]} -eq 1 ] || die "expected one SDK installer under $wt/build/yocto, found ${#sdk[@]}"
  mkdir -p "$stage/sdk"
  shopt -s nullglob
  cp -a "${sdk[0]}" "${sdk[0]%.sh}".*manifest "$stage/sdk/"   # installer, host and target package lists
  shopt -u nullglob
  sdk_note="built (\`sdk/\`)"
else
  sdk_note="not built (RELEASE_SDK=0)"
fi

# shellcheck disable=SC1091
hil_id=$(. "$wt/out/hil/stage.env" && echo "$HIL_ID")
cp -a "$wt/out/hil/$hil_id/latest/." "$stage/hil/"

# Release notes: the facts filled in, the rest left for a person (see the template).
junit="$stage/hil/junit.xml"
hil_summary=$(python3 - "$junit" <<'PY'
import sys, xml.etree.ElementTree as ET
s = ET.parse(sys.argv[1]).getroot()
s = s if s.tag == "testsuite" else s.find("testsuite")
props = {p.get("name"): p.get("value") for p in s.iter("property")}
print(f"{s.get('tests')} tests, {s.get('failures')} failures, {s.get('errors')} errors, "
      f"{s.get('skipped')} skipped" + "".join(f"; {k} = {v}" for k, v in props.items()))
PY
)
sed -e "s|@TAG@|$tag|g" \
    -e "s|@DATE@|$(date -u +%Y-%m-%d)|g" \
    -e "s|@COMMIT@|$(git rev-parse --short=12 "$tag^{commit}")|g" \
    -e "s|@PL_STEM@|$stem|g" \
    -e "s|@HIL_SUMMARY@|$hil_summary|g" \
    -e "s|@SDK@|$sdk_note|g" \
    -e "s|@BUILD_TIME@|$(( ($(date -u +%s) - start) / 60 )) min|g" \
    "$root/docs/release-notes-template.md" > "$stage/RELEASE_NOTES.md"

cp -a "$log" "$stage/release.log"
( cd "$stage" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -d '\n' sha256sum > SHA256SUMS )

# Never overwrite: -T with a missing target is a rename; it fails if dest appeared meanwhile.
[ ! -e "$dest" ] || die "$dest appeared during the build; this attempt stays in $stage"
mv -T "$stage" "$dest"
say "released $tag: $dest"

if [ "${RELEASE_KEEP:-0}" = 1 ]; then
  say "worktree kept: $wt"
else
  git worktree remove --force "$wt"
fi
say "next: complete $dest/RELEASE_NOTES.md, then push the tag: git push origin $tag"

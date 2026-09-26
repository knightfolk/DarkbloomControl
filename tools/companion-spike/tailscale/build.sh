#!/bin/bash
# TEST ONLY. Every generated source/binary/state file stays under ignored .build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tools/companion-spike/tailscale"
BUILD="$ROOT/.build/companion-spike"
PIN=59d4bb82744915815178e0f0776d60026a397ee7
export GOTOOLCHAIN=auto GOFLAGS=-p=4 GOMAXPROCS=4 TS_NO_LOGS_NO_SUPPORT=true
mkdir -p "$ROOT/.build"
SOURCE="${LIBTAILSCALE_SOURCE:-$ROOT/.build/libtailscale-upstream}"
if [[ ! -d "$SOURCE/.git" ]]; then
 git clone https://github.com/tailscale/libtailscale.git "$SOURCE" >&2
fi
git -C "$SOURCE" cat-file -e "$PIN^{commit}"
STAGE="$(mktemp -d "$ROOT/.build/companion-spike-stage.XXXXXX")"
# Fresh staging excludes stale source. Preserve failed stages for diagnosis.
git -C "$SOURCE" archive "$PIN" | tar -x -C "$STAGE"
(cd "$STAGE" && patch -p1 < "$HERE/bounded-descriptors.patch") >&2
cp "$HERE/go.mod" "$HERE/go.sum" "$STAGE/"
cp "$HERE/overlay/"*.go "$STAGE/"
mkdir -p "$STAGE/spikefixture"
cp "$HERE/overlay/spikefixture/"*.go "$STAGE/spikefixture/"
cd "$STAGE"
go mod verify >&2
go test -c -o fixture . >&2
if [[ -e "$BUILD" ]]; then
 PREVIOUS="$(mktemp -d "$ROOT/.build/companion-spike-previous.XXXXXX")"
 mv "$BUILD" "$PREVIOUS/source"
 printf 'Preserved previous fixture source/build: %s\n' "$PREVIOUS/source" >&2
fi
mv "$STAGE" "$BUILD"
printf '%s\n' "$BUILD/fixture"

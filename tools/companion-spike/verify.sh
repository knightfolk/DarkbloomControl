#!/bin/bash
# Local synthetic proof only. Does not enroll a tailnet or operate Darkbloom.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mkdir -p "$HERE/.build"
RUN="$(mktemp -d "$HERE/.build/verification.XXXXXX")"
printf 'Evidence directory: %s\n' "$RUN"
trap 'printf "Verification stopped; inspect %s\n" "$RUN" >&2' ERR

swift test --package-path "$HERE" --jobs 4 > "$RUN/native-tests.log" 2>&1
swift build --package-path "$HERE" --product TLSBridgeHarness --jobs 4 > "$RUN/native-build.log" 2>&1
BIN="$(swift build --package-path "$HERE" --show-bin-path)/TLSBridgeHarness"
"$HERE/tailscale/build.sh" > "$RUN/fixture-path.txt" 2> "$RUN/fixture-build.log"
(
    cd "$ROOT/.build/companion-spike"
    unset SPIKE_TARGET_PORT
    export GOTOOLCHAIN=auto GOFLAGS=-p=4 GOMAXPROCS=4 TS_NO_LOGS_NO_SUPPORT=true
    go test -race -run '^TestSpike' -count=1 -timeout 90s -v . > "$RUN/bridge-race-tests.log" 2>&1
)
"$BIN" > "$RUN/native-mtls.jsonl" 2> "$RUN/native-mtls.stderr"
"$BIN" --bridge "$ROOT/.build/companion-spike/fixture" > "$RUN/embedded-mtls.jsonl" 2> "$RUN/embedded-mtls.stderr"
python3 - "$RUN" <<'PY'
import json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
for name in ('native-mtls', 'embedded-mtls'):
    rows = [json.loads(line) for line in (directory / (name + '.jsonl')).read_text().splitlines()]
    assert rows and rows[-1] == {'assertion': 'harnessCompleted', 'passed': True}, name
    assert all(row.get('passed') is True for row in rows), name
    print(f'{name}: {len(rows)} assertions passed')
print('This local run passed. The recorded intermittent embedded data-loss blocker remains open; one passing run does not qualify the adapter. Physical device and real WAN gates remain open.')
PY

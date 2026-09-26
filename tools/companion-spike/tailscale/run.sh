#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export TS_NO_LOGS_NO_SUPPORT=true GOMAXPROCS=4
: "${SPIKE_TARGET_PORT:?Set SPIKE_TARGET_PORT to the native test TLS server port}"
exec "$ROOT/.build/companion-spike/fixture" -test.run '^TestSpikeProcess$' -test.timeout 200s

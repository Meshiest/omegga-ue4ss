#!/usr/bin/env bash
# run by `omegga install`: build the TypeScript. The UE4SS runtime is fetched on
# the first server start (see runtimeUrl), or placed in runtime/ by hand.
set -euo pipefail
cd "$(dirname "$0")"
npm ci --no-audit --no-fund
npm run build

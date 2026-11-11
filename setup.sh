#!/usr/bin/env bash
# run by omegga on `omegga install` and on every plugin update: build the
# TypeScript, then download the native binaries this source needs (only the
# ones whose source changed; see tools/fetch-runtime.ts, which Node runs
# directly). A server start only checks them, without the network.
set -euo pipefail
cd "$(dirname "$0")"
npm ci --no-audit --no-fund
npm run build
node --experimental-strip-types --disable-warning=MODULE_TYPELESS_PACKAGE_JSON tools/fetch-runtime.ts

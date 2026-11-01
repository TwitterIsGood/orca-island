#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/LocalHTTPServer.swift \
  tests/HTTPServerTests.swift \
  -o .validation/http-server-tests
.validation/http-server-tests

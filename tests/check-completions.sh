#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/NotchGeometry.swift \
  companion/Sources/OrcaIsland/Models.swift \
  tests/CompletionTests.swift \
  -o .validation/completion-tests
.validation/completion-tests

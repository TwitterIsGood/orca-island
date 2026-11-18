#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/NotchGeometry.swift \
  companion/Sources/OrcaIsland/Models.swift \
  companion/Sources/OrcaIsland/TerminalSwitcher.swift \
  tests/IslandAcknowledgementTests.swift \
  -o .validation/island-acknowledgement-tests
.validation/island-acknowledgement-tests

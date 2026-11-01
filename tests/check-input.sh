#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/NotchPanel.swift \
  tests/NotchPanelInputTests.swift \
  -o .validation/notch-panel-input-tests
.validation/notch-panel-input-tests

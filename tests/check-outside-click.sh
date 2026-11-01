#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/OutsideClickMonitor.swift \
  tests/OutsideClickMonitorTests.swift \
  -o .validation/outside-click-monitor-tests
.validation/outside-click-monitor-tests

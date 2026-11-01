#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/PollSchedule.swift \
  companion/Sources/OrcaIsland/OrcaStatusPoller.swift \
  tests/EventSyncTests.swift \
  -o .validation/event-sync-tests
.validation/event-sync-tests

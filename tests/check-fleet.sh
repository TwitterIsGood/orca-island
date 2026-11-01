#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc companion/Sources/OrcaIsland/NotchGeometry.swift \
  companion/Sources/OrcaIsland/Models.swift \
  companion/Sources/OrcaIsland/PollSchedule.swift \
  companion/Sources/OrcaIsland/OrcaStatusPoller.swift \
  companion/Sources/OrcaIsland/OrcaSnapshotReader.swift \
  tests/FleetSyncTests.swift -o .validation/fleet-sync-tests
.validation/fleet-sync-tests
node --test tests/orca-projection.test.cjs

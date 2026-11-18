#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc companion/Sources/OrcaIsland/NotchGeometry.swift \
  companion/Sources/OrcaIsland/Models.swift \
  companion/Sources/OrcaIsland/PollSchedule.swift \
  companion/Sources/OrcaIsland/OrcaStatusPoller.swift \
  companion/Sources/OrcaIsland/OrcaCommandRunner.swift \
  companion/Sources/OrcaIsland/OrcaPublicCLI.swift \
  companion/Sources/OrcaIsland/OrcaSnapshotReader.swift \
  tests/PublicCLITests.swift -o .validation/public-cli-tests
.validation/public-cli-tests

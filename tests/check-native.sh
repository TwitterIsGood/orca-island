#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc \
  companion/Sources/OrcaIsland/NotchGeometry.swift \
  tests/NotchGeometryTests.swift \
  -o .validation/notch-geometry-tests
.validation/notch-geometry-tests

swiftc \
  companion/Sources/OrcaIsland/NotchGeometry.swift \
  companion/Sources/OrcaIsland/NotchSilhouette.swift \
  companion/Sources/OrcaIsland/Models.swift \
  companion/Sources/OrcaIsland/OverlayView.swift \
  tests/OverlayLayoutTests.swift \
  -o .validation/overlay-layout-tests
.validation/overlay-layout-tests

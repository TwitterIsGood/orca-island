#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
swiftc companion/Sources/OrcaIsland/NotchGeometry.swift companion/Sources/OrcaIsland/Models.swift companion/Sources/OrcaIsland/BridgeMessage.swift tests/BridgeMessageTests.swift -o .validation/bridge-message-tests
.validation/bridge-message-tests

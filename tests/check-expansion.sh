#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .validation
sources=()
for source in companion/Sources/OrcaIsland/*.swift; do
  if [[ "$source" != */OrcaIslandApp.swift ]]; then
    sources+=("$source")
  fi
done
swiftc "${sources[@]}" tests/ExpansionLatencyTests.swift -o .validation/expansion-latency-tests
.validation/expansion-latency-tests

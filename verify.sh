#!/bin/zsh
set -euo pipefail
bridge_source="${0:A:h}"
mkdir -p "$bridge_source/Build"
swiftc -parse-as-library "$bridge_source/Sources/Models.swift" "$bridge_source/Sources/PlaybackLogMonitor.swift" "$bridge_source/Tests/BehaviorChecks.swift" -o "$bridge_source/Build/checks"
"$bridge_source/Build/checks"

if [[ "${1:-}" == "--live" ]]; then
  swiftc -parse-as-library "$bridge_source/Sources/Models.swift" "$bridge_source/Sources/MDDPageClient.swift" "$bridge_source/Tests/CacheCheck.swift" -o "$bridge_source/Build/check-cache"
  "$bridge_source/Build/check-cache" "${2:-}"
fi

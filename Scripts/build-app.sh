#!/bin/bash
# Builds Mog.app (menu-bar app) into .build/Mog.app, with the face model inside it.
# No login item, no launch agent, nothing installed. Homebrew users: `mog install-app` instead.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -d Models/FaceEmbedding.mlmodelc ] || ./Scripts/fetch-model.sh

swift build -c release --product mog
swift build -c release --product MogBar
.build/release/mog install-app --dir .build --embed-model

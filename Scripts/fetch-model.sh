#!/bin/bash
# Downloads the ArcFace Core ML model, verifies its checksum, and compiles it for this Mac.
# Model: ArcFace LResNet100E-IR (ONNX Model Zoo, Apache-2.0), Core ML fp16 conversion by
# RuiSumida on Hugging Face. ~110 MB download, ~125 MB compiled. Runs fully offline afterwards.
# (Homebrew installs do this themselves; this script is for building from a clone.)
set -euo pipefail

cd "$(dirname "$0")/.."
URL='https://huggingface.co/RuiSumida/ArcFace-R100-CoreML/resolve/b51b655da6b4acc72bfdbfdcd316b3cf4f698e4e/FaceEmbedding.mlpackage.tar.gz'
SHA256='3644ff110ba03a082515d3a9fa22dbc8c1eb66054bb6bbbc0e84eb62b4771f2b'
ARCHIVE='Models/FaceEmbedding.mlpackage.tar.gz'
COMPILED='Models/FaceEmbedding.mlmodelc'

mkdir -p Models
if [ -d "$COMPILED" ]; then
    echo "already installed: $COMPILED"
    exit 0
fi

if [ ! -f "$ARCHIVE" ]; then
    echo "downloading model (~110 MB)…"
    curl --fail --location --progress-bar "$URL" -o "$ARCHIVE.part"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi

actual=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$actual" != "$SHA256" ]; then
    echo "checksum mismatch: got $actual, expected $SHA256" >&2
    rm -f "$ARCHIVE"
    exit 1
fi
echo "checksum ok"

rm -rf Models/FaceEmbedding.mlpackage
tar -xzf "$ARCHIVE" -C Models

echo "compiling for this Mac…"
swift build -c release --product mog
.build/release/mog compile-model Models/FaceEmbedding.mlpackage "$COMPILED"
rm -rf Models/FaceEmbedding.mlpackage
echo "installed: $COMPILED"

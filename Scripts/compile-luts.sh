#!/bin/bash
# Compiles the .cube look sources into the .gclut files the app ships.
#
# Sources live in LUTSources/, outside the app folder so they cannot be bundled;
# only the compiled output is bundled. Pass --check to verify the committed
# output matches the sources without rewriting it.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d /tmp/gradelab-lut-compiler.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun swiftc -module-cache-path /tmp/gradelab-lut-module-cache -Onone \
    -o "$BUILD_DIR/compile-luts" \
    Scripts/CompileLUTs.swift \
    'dummy name/Core/AppError.swift' \
    'dummy name/Core/LUT/CubeLUT.swift' \
    'dummy name/Core/LUT/CubeLUTParser.swift' \
    'dummy name/Core/LUT/LookValidation.swift' \
    'dummy name/Core/LUT/LUTBinary.swift'
"$BUILD_DIR/compile-luts" "$@" \
    'LUTSources' \
    'dummy name/Resources/LUTs'

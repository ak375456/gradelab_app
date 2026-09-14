#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d /tmp/gradelab-log-validator.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR/LogValidator.app/Contents/MacOS" "$BUILD_DIR/LogValidator.app/Contents/Resources"
cp 'dummy name/Resources/LUTs/Imported/Apple_Log_To_Rec_709.cube' "$BUILD_DIR/LogValidator.app/Contents/Resources/"
python3 - "$BUILD_DIR/LogValidator.app/Contents/MacOS/validate" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path('dummy name/Core')
files = [root / 'AppError.swift']
for folder in ['Grading', 'Timeline', 'LUT', 'Export', 'Rendering', 'Video']:
    files += sorted((root / folder).glob('*.swift'))
excluded = {'LookPreviewRenderer.swift', 'ThumbnailGenerator.swift', 'MetalPreviewView.swift',
            'MetalVideoRenderer.swift', 'ImageExporter.swift', 'ImageExportConfiguration.swift'}
files = [str(p) for p in files if p.name not in excluded]
files += [str(root / p) for p in ['Projects/VideoProject.swift', 'Projects/GradeProject.swift',
    'Images/ImageMetadata.swift', 'Images/ImageColorSupport.swift',
    'Playback/PreviewQuality.swift', 'Playback/PreviewCompositions.swift']]
subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/tmp/gradelab-log-module-cache', '-Onone', '-D', 'APPLE_LOG_VALIDATOR', '-o', sys.argv[1],
    'Scripts/ValidateAppleLogLayers.swift', 'GradeLabTests/AppleLogLayerHarness.swift', *files], check=True)
PY
"$BUILD_DIR/LogValidator.app/Contents/MacOS/validate" "$@"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/gradelab-noise.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path('dummy name/Core')
build = Path(sys.argv[1])
files = [root / 'AppError.swift']
for folder in ['NoiseReduction', 'Grading', 'Timeline', 'LUT', 'Export', 'Rendering',
               'Video', 'BackgroundRemoval', 'ShotMatch']:
    files += sorted((root / folder).glob('*.swift'))
# The same exclusions the other harnesses use: anything needing UIKit, a decoded
# frame or a live render surface is not what is under test here.
excluded = {'LookPreviewRenderer.swift', 'ThumbnailGenerator.swift', 'MetalPreviewView.swift',
            'MetalVideoRenderer.swift', 'ImageExporter.swift', 'ImageExportConfiguration.swift',
            'BackgroundRemovalAnalyzer.swift', 'BackgroundLassoTracker.swift',
            'ShotMatchAnalysisRenderer.swift', 'ShotMatchEngine.swift',
            'ShotMatchFrameSource.swift'}
files = [str(p) for p in files if p.name not in excluded]
files += [str(root / p) for p in ['Projects/VideoProject.swift', 'Projects/GradeProject.swift',
    'Projects/ProjectStore.swift', 'Projects/ProjectLibraryStorage.swift',
    'Import/AudioImportService.swift', 'Images/ImageMetadata.swift',
    'Images/ImageColorSupport.swift', 'Playback/PreviewQuality.swift',
    'Playback/PreviewCompositions.swift']]
subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(build / 'modules'), '-O',
    '-o', str(build / 'validate'),
    'Scripts/ValidateNoiseReduction.swift', *files], check=True)
PY
"$build_dir/validate"

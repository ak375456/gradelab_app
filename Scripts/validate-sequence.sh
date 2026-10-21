#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/gradelab-sequence.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PY'
from pathlib import Path
import platform, subprocess, sys
root = Path('dummy name/Core')
build = Path(sys.argv[1])
files = [root / 'AppError.swift']
for folder in ['Audio', 'Grading', 'Timeline', 'LUT', 'Export', 'Rendering', 'Video',
               'BackgroundRemoval', 'ShotMatch', 'NoiseReduction', 'Relight', 'Retiming', 'Playback', 'Tracking']:
    files += sorted((root / folder).glob('*.swift'))
excluded = {'LookPreviewRenderer.swift', 'ThumbnailGenerator.swift', 'MetalPreviewView.swift',
            'MetalVideoRenderer.swift', 'ImageExporter.swift', 'ImageExportConfiguration.swift',
            'BackgroundRemovalAnalyzer.swift', 'BackgroundLassoTracker.swift',
            'ShotMatchAnalysisRenderer.swift', 'ShotMatchEngine.swift',
            'ShotMatchFrameSource.swift'}
files = [str(p) for p in files if p.name not in excluded and p.name != 'SoundEffectLibrary.swift']
files += [str(root / p) for p in ['Projects/VideoProject.swift', 'Projects/GradeProject.swift',
    'Projects/ProjectStore.swift', 'Projects/ProjectLibraryStorage.swift', 'Import/AudioImportService.swift',
    'Images/ImageMetadata.swift', 'Images/ImageColorSupport.swift']]
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
# The current export path shares playback's AVAudioSession settings. Compile
# this host harness for Catalyst, just like the app's Mac target, without a simulator.
subprocess.run(['xcrun', 'swiftc', '-target', platform.machine() + '-apple-ios18.0-macabi',
    '-sdk', str(sdk), '-F', str(sdk / 'System/iOSSupport/System/Library/Frameworks'),
    '-I', str(sdk / 'System/iOSSupport/usr/include'),
    '-j', '4', '-module-cache-path', str(build / 'modules'), '-Onone',
    '-D', 'APPLE_LOG_VALIDATOR', '-o', str(build / 'validate'),
    'Scripts/ValidateSequence.swift', *files], check=True)
PY
"$build_dir/validate"

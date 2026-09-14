#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/gradelab-camera-audio.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$build_dir/Validator.app/Contents/MacOS" "$build_dir/Validator.app/Contents/Resources"
cp 'dummy name/Resources/LUTs/Imported/Apple_Log_To_Rec_709.cube' "$build_dir/Validator.app/Contents/Resources/"
sources=('dummy name/Core/AppError.swift')
for folder in Grading Timeline LUT Export Rendering Video; do
    for source in "dummy name/Core/$folder/"*.swift; do
        case "$source" in
            */LookPreviewRenderer.swift|*/ThumbnailGenerator.swift|*/MetalPreviewView.swift|*/MetalVideoRenderer.swift|*/ImageExporter.swift|*/ImageExportConfiguration.swift) continue ;;
        esac
        sources+=("$source")
    done
done
for source in Projects/VideoProject.swift Projects/GradeProject.swift Images/ImageMetadata.swift Images/ImageColorSupport.swift Playback/PreviewQuality.swift Playback/PreviewCompositions.swift; do
    sources+=("dummy name/Core/$source")
done
xcrun swiftc -module-cache-path "$build_dir/module-cache" -Onone -D APPLE_LOG_VALIDATOR \
    -o "$build_dir/Validator.app/Contents/MacOS/validate" \
    Scripts/ValidateCameraAudioExport.swift "${sources[@]}"
"$build_dir/Validator.app/Contents/MacOS/validate" "$@"

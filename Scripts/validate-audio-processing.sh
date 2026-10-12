#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audio_build_dir=$(mktemp -d /tmp/gradelab-audio-validation.XXXXXX)
trap 'rm -rf "$audio_build_dir"' EXIT
xcrun swiftc -O -module-cache-path "$audio_build_dir/module-cache" \
    Scripts/ValidateAudioProcessing.swift \
    'dummy name/Core/Audio/AudioProcessingSettings.swift' \
    'dummy name/Core/Audio/AudioDSP.swift' \
    'dummy name/Core/Audio/AudioSpaceDSP.swift' \
    'dummy name/Core/Audio/AudioProcessingTap.swift' \
    'dummy name/Core/Audio/AudioStereoSource.swift' \
    -o "$audio_build_dir/validate"
"$audio_build_dir/validate"

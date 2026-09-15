#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <essential-mp3-directory> <sound-design-wav-directory> <output-directory>" >&2
    exit 64
fi

essential_source=$1
design_source=$2
output_directory=$3
ffmpeg_binary=${FFMPEG_BINARY:-/opt/homebrew/bin/ffmpeg}
ffprobe_binary=${FFPROBE_BINARY:-/opt/homebrew/bin/ffprobe}

for directory in "$essential_source" "$design_source"; do
    if [[ ! -d "$directory" ]]; then
        echo "Source directory does not exist: $directory" >&2
        exit 66
    fi
done

for binary in "$ffmpeg_binary" "$ffprobe_binary" /usr/bin/jq; do
    if [[ ! -x "$binary" ]]; then
        echo "Required tool is unavailable: $binary" >&2
        exit 69
    fi
done

if [[ -e "$output_directory" ]]; then
    echo "Output already exists; move it aside before rebuilding: $output_directory" >&2
    exit 73
fi

mkdir -p "$output_directory"
manifest_lines=$(mktemp)
trap 'rm -f "$manifest_lines"' EXIT

duration_of() {
    "$ffprobe_binary" -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1"
}

essential_category() {
    local lowercase
    lowercase=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$lowercase" in
        *whoosh*|*woosh*|*swoosh*|*whiz*|*sweep*) echo "Whooshes" ;;
        *hit*|*impact*|*thump*|*slap*|*pound*|*whip*|*clap*|*stamp*) echo "Hits" ;;
        *glitch*|*static*|*rewind*|*synth*|*zap*|*sonic*) echo "Glitches" ;;
        *water*|*rain*|*thunder*|*wind*|*forest*|*ocean*|*stream*) echo "Nature" ;;
        *bird*|*cricket*|*donkey*|*duck*|*animal*) echo "Animals" ;;
        *car*|*engine*|*helicopter*|*train*|*boat*) echo "Vehicles" ;;
        *gun*|*explosion*|*siren*) echo "Action" ;;
        *crowd*|*laugh*|*gasp*|*scream*|*grunt*|*exhale*|*snore*) echo "People" ;;
        *door*|*footstep*|*paper*|*plastic*|*zipper*|*toilet*|*tape*|*typing*) echo "Foley" ;;
        *click*|*notification*|*alert*|*ding*|*chime*|*bell*|*censor*) echo "UI & Alerts" ;;
        *ambient*) echo "Ambience" ;;
        *music*|*drum*|*jingle*|*organ*|*harp*|*string*|*horn*) echo "Musical" ;;
        *) echo "Other" ;;
    esac
}

append_manifest_item() {
    /usr/bin/jq -nc \
        --arg id "$1" \
        --arg title "$2" \
        --arg category "$3" \
        --arg pack "$4" \
        --arg resource "$5" \
        --argjson duration "$6" \
        '{id: $id, title: $title, category: $category, pack: $pack, resource: $resource, duration: $duration}' \
        >> "$manifest_lines"
}

essential_index=0
while IFS= read -r source_file; do
    essential_index=$((essential_index + 1))
    resource=$(printf 'essential_%04d.mp3' "$essential_index")
    cp "$source_file" "$output_directory/$resource"
    base=$(basename "$source_file")
    title=${base%.*}
    case "$title" in
        *.MP3|*.mp3) title="${title%.*} (Alternate)" ;;
    esac
    title=${title//_/ }
    category=$(essential_category "$title")
    append_manifest_item "essential-$essential_index" "$title" "$category" "Essential Effects" \
        "$resource" "$(duration_of "$source_file")"
done < <(find "$essential_source" -maxdepth 1 -type f -iname '*.mp3' | LC_ALL=C sort)

design_index=0
while IFS= read -r source_file; do
    design_index=$((design_index + 1))
    resource=$(printf 'sound_design_%04d.m4a' "$design_index")
    "$ffmpeg_binary" -v error -nostdin -i "$source_file" -map_metadata -1 -vn \
        -c:a aac -b:a 192k -ar 44100 -ac 2 -movflags +faststart \
        "$output_directory/$resource"
    category=$(basename "$(dirname "$source_file")")
    case "$category" in
        "Cinematic Hits") category="Cinematic Hits" ;;
        "Foley:Humans") category="Foley" ;;
        "Riser") category="Risers" ;;
        "Whooshs") category="Whooshes" ;;
    esac
    base=$(basename "$source_file" .wav)
    title=${base%% - \(*}
    source_category=$(basename "$(dirname "$source_file")")
    title=${title% - $source_category}
    title=${title//_/ }
    append_manifest_item "sound-design-$design_index" "$title" "$category" "Sound Design Essentials" \
        "$resource" "$(duration_of "$source_file")"
done < <(find "$design_source" -type f -iname '*.wav' | LC_ALL=C sort)

/usr/bin/jq -s \
    --argjson version 1 \
    --arg generatedBy "Scripts/BuildSoundEffectLibrary.sh" \
    '{version: $version, generatedBy: $generatedBy, effects: .}' \
    "$manifest_lines" > "$output_directory/SoundEffects.json"

echo "Built $((essential_index + design_index)) offline sound effects in $output_directory"

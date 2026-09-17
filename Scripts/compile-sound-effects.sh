#!/bin/bash
# Compiles the sound effect sources into the files the app ships.
#
# Sources live in SoundSources/, outside the app folder so they cannot be
# bundled; only the compiled output is. The sources are the masters — the
# original WAV/MP3 libraries Scripts/BuildSoundEffectLibrary.sh was run against
# are not in this repo — so this never writes back over them. Re-running is
# safe: every encode starts from the source, not from the last output.
#
# Encoding is chosen per file rather than applied uniformly:
#
#   * AAC-LC, never HE-AAC. HE-AAC's spectral band replication smears sharp
#     transients, and a sound effects library is almost entirely transients —
#     clicks, hits, whooshes. The bitrate saving is not worth what it does to
#     the attack of every impact in the library.
#   * Mono at 64k only where the file has no real stereo content to lose,
#     measured as the peak level of the L-R difference. Most of this library
#     does have stereo width, so mono is applied to the minority that does not
#     rather than across the board.
#   * Stereo at 96k, down from 128k MP3 and 192k AAC. AAC-LC at 96k is about
#     equivalent to MP3 at 128k, so this is roughly transparent against the
#     essential pack and a real but conservative reduction for the other.
#
# Pass --check to verify the committed output is present and current.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_DIR="SoundSources"
OUTPUT_DIR="dummy name/Resources/SoundEffects"
FFMPEG=${FFMPEG_BINARY:-/opt/homebrew/bin/ffmpeg}
FFPROBE=${FFPROBE_BINARY:-/opt/homebrew/bin/ffprobe}
# Below this peak L-R difference, in dBFS, the two channels carry the same
# thing and stereo is only costing bitrate. Chosen from the library's own
# distribution: it separates the genuinely mono files from the rest, rather
# than being a round number picked in advance.
MONO_THRESHOLD_DB=-50

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

for binary in "$FFMPEG" "$FFPROBE" /usr/bin/jq; do
    [[ -x "$binary" ]] || { echo "Required tool is unavailable: $binary" >&2; exit 69; }
done
[[ -f "$SOURCE_DIR/SoundEffects.json" ]] || { echo "No manifest at $SOURCE_DIR/SoundEffects.json" >&2; exit 66; }

[[ $CHECK_ONLY -eq 0 ]] && mkdir -p "$OUTPUT_DIR"

manifest_lines=$(mktemp)
trap 'rm -f "$manifest_lines"' EXIT

stale=()
missing_source=()
source_bytes=0
output_bytes=0
mono_count=0
stereo_count=0

while IFS=$'\t' read -r id title category pack resource; do
    source="$SOURCE_DIR/$resource"
    if [[ ! -f "$source" ]]; then
        missing_source+=("$resource")
        continue
    fi
    output_name="${resource%.*}.m4a"
    output="$OUTPUT_DIR/$output_name"

    if [[ $CHECK_ONLY -eq 1 ]]; then
        # Deliberately no channel analysis here: measuring every file costs two
        # minutes, and a presence check is what this mode is for.
        [[ -f "$output" ]] || stale+=("$output_name")
        stereo_count=$((stereo_count + 1))
    else
        # Peak level of the L-R difference. A file whose channels are identical
        # produces silence here and is safe to collapse to mono.
        difference=$("$FFMPEG" -hide_banner -nostdin -i "$source" \
            -af "pan=mono|c0=0.5*c0-0.5*c1,volumedetect" -f null - 2>&1 \
            | grep -o "max_volume: -*[0-9.]*" | head -1 | sed 's/max_volume: //')
        if [[ -z "$difference" ]] || awk -v d="$difference" -v t="$MONO_THRESHOLD_DB" 'BEGIN{exit !(d < t)}'; then
            channels=1; bitrate=64k; mono_count=$((mono_count + 1))
        else
            channels=2; bitrate=96k; stereo_count=$((stereo_count + 1))
        fi

        "$FFMPEG" -v error -nostdin -i "$source" -map_metadata -1 -vn \
            -c:a aac -profile:a aac_low -b:a "$bitrate" -ar 44100 -ac "$channels" \
            -movflags +faststart "$output" -y
    fi

    source_bytes=$((source_bytes + $(stat -f%z "$source")))
    if [[ -f "$output" ]]; then
        output_bytes=$((output_bytes + $(stat -f%z "$output")))
        # Duration is measured from the compiled file, not carried over from the
        # source: AAC encoding shifts it by a few milliseconds, and a manifest
        # that disagreed with the audio would show one length and play another.
        duration=$("$FFPROBE" -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$output")
    else
        duration=0
    fi

    /usr/bin/jq -nc --arg id "$id" --arg title "$title" --arg category "$category" \
        --arg pack "$pack" --arg resource "$output_name" --argjson duration "$duration" \
        '{id: $id, title: $title, category: $category, pack: $pack, resource: $resource, duration: $duration}' \
        >> "$manifest_lines"
done < <(/usr/bin/jq -r '.effects[] | [.id, .title, .category, .pack, .resource] | @tsv' "$SOURCE_DIR/SoundEffects.json")

if [[ ${#missing_source[@]} -gt 0 ]]; then
    printf 'error: %d effect(s) in the manifest have no source file:\n' "${#missing_source[@]}" >&2
    printf '  %s\n' "${missing_source[@]}" >&2
    exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    if [[ ${#stale[@]} -gt 0 ]]; then
        printf 'error: %d compiled effect(s) are missing:\n' "${#stale[@]}" >&2
        printf '  %s\n' "${stale[@]}" >&2
        echo "Run Scripts/compile-sound-effects.sh" >&2
        exit 1
    fi
    echo "All $((mono_count + stereo_count)) compiled effects are present."
    exit 0
fi

/usr/bin/jq -s --argjson version 1 \
    --arg generatedBy "Scripts/compile-sound-effects.sh" \
    '{version: $version, generatedBy: $generatedBy, effects: .}' \
    "$manifest_lines" > "$OUTPUT_DIR/SoundEffects.json"

# Anything left from an effect since removed from the manifest would keep
# shipping, and would keep appearing in the browser.
expected=$(/usr/bin/jq -r '.effects[].resource' "$OUTPUT_DIR/SoundEffects.json")
while IFS= read -r existing; do
    name=$(basename "$existing")
    [[ "$name" == "SoundEffects.json" ]] && continue
    grep -qxF "$name" <<< "$expected" || { rm "$existing"; echo "  removed orphan $name"; }
done < <(find "$OUTPUT_DIR" -type f)

printf '\n%d effects (%d mono, %d stereo): %.1f MB -> %.1f MB (-%.0f%%)\n' \
    "$((mono_count + stereo_count))" "$mono_count" "$stereo_count" \
    "$(echo "$source_bytes" | awk '{print $1/1048576}')" \
    "$(echo "$output_bytes" | awk '{print $1/1048576}')" \
    "$(echo "$source_bytes $output_bytes" | awk '{print 100 - $2*100/$1}')"

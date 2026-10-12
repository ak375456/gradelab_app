# Audio tools

Select a video with linked sound, or a standalone audio clip, then open **Audio**.
Changes affect only that clip. Locked clips and tracks must be unlocked first.

- **Basic**: volume, mute, left/right pan (balance), fade in and fade out.
- **Tone** (expand to open): Warm Voice, Telephone, Muffled, Bright Voice; Bass,
  Mids and Treble from −12 to +12 dB. Presets update these ordinary EQ controls.
- **Advanced** inside Tone: Low cut (off or 20–500 Hz) and High cut
  (1–20 kHz, with 20 kHz meaning off). Cutoffs stay below the source Nyquist limit.
- **Tone on**: switch off to compare the original tone. EQ values are retained;
  volume, fades and pan continue to apply. Applying a preset enables Tone again.
- **Reset** inside Tone: restores flat tone and keeps Basic settings and all other effects.
- **Compressor**: enable, then adjust Amount to even out loud moments. Advanced
  exposes threshold, ratio, attack, release and makeup gain. Amount adjusts threshold
  and ratio together; Advanced lets you override either. Makeup starts at 0 dB.
  The detector links stereo channels and uses a soft knee, without lookahead.
- **Auto Ducking**: select the music clip, enable Ducking, and choose another
  audio/video clip as the Voice source. Reduction sets how far music drops;
  Lower before anticipates speech and Recover restores music after it. Voice
  threshold controls activity detection. The mini envelope shows the resulting
  music level. This detects audio activity, not speech semantics: select a clean
  voice recording and raise the threshold if background sound triggers it.
- **Echo & Reverb**: independent switches and mix controls; echo time/feedback;
  reverb size/damping. Slapback, Small room and Hall presets are starting points.
- **Texture**: distortion and bitcrusher, each with its own Amount slider.
  Switch an effect off to compare while preserving its settings.
- **Clip level**: the selected clip's post-volume/fade/EQ peak during playback,
  including all enabled effects, in dBFS. It is not the combined level of every audio track. Above 0 dBFS,
  lower Volume to avoid clipping. Pausing clears the reading.

Double-tap a slider to reset it, or tap its number to enter an exact value.
Fades are seconds and are limited to half the clip, up to 10 seconds each.
New effects start off. Their processing order is clip volume/fades/ducking →
compressor → tone → distortion/bitcrusher → echo → reverb → pan. Effect delay
lines are allocated during preparation, with no render-callback allocation.
Echo/reverb tails stop at the scheduled audio clip edge; extend the source with
silence if a tail needs more room. Seeking clears effect history, so a seek into
an existing tail starts clean. These are lightweight algorithmic effects.

Ducking analyzes the chosen voice's scheduled composition tracks during
preparation, so trims, moves, speed changes and source-track selection carry
through. It joins pauses shorter than 120 ms, then builds a shared preview/export
volume envelope. Muted/disabled/deleted sources produce no reduction. It measures
source audio before tone and creative effects, including source volume/fades.
Rebuilding a timeline reanalyzes selected sources; adjusting reduction/recovery
reuses the analysis. Each voice's analysis is bounded to 65,536 peak bins.
Center pan preserves the original stereo image; moving left/right reduces the
opposite channel. Mono sources are mixed to stereo before this balance applies.
The first preparation of a mono source creates a lossless stereo file in the
app's disposable cache; later previews and exports reuse it. This costs initial
decode time and cache space, while the original recording stays untouched.

## Manual acceptance test

Use headphones and a 10–20 second spoken clip, plus a music clip. Test linked
video audio and a standalone WAV/M4A import.

1. Play the clip; lower Volume to 50%, mute, then unmute. The meter should follow
   playback and fall to Silent while muted or paused. Change Pan fully left and
   right: sound should move between ears. Center restores the original balance.
2. Set both fades to 1 second. Play from the beginning and through the end; the
   level should rise/fall smoothly without moving the picture or other clips.
3. Expand Tone. Try each preset. Telephone should lose deep bass and high detail;
   Muffled should lose the most high detail. Warm is fuller; Bright adds presence.
   Check the visible EQ values change with the preset.
4. Adjust Bass/Mids/Treble. The preset summary becomes Custom. Open Advanced,
   raise Low cut and lower High cut; hear rumble/detail reduce respectively.
5. Switch Tone off/on while playing. Your edited values should remain visible,
   and pan, fades and volume should still work. Reset returns flat EQ and keeps
   the Basic settings. Double-tap a slider and try numerical entry.
6. Undo/redo the preset and a slider drag. Save, leave and reopen the project.
   Separate linked audio, split, duplicate and trim it: tone/pan should survive;
   fades stay on the original outside edges after a split.
7. Export a short movie and listen in another player. Check EQ, pan, mute and
   fades match the editor, including a mono recording. Mix two audio clips and
   verify changing one clip's tone does not affect the other.
8. Enable Compressor on speech with loud and quiet phrases. Raise Amount:
   loud phrases should settle down while quiet phrases stay close to their level.
   Check Advanced threshold/ratio and attack/release, then switch off/on. Add
   Makeup only as needed and watch for clipping. Pan must stay consistent.
9. Put music beneath a voice with clear pauses. Select music → Auto Ducking →
   choose the voice. Listen for reduction during phrases and recovery in pauses.
   Adjust Reduction, Lower before, Recover and Voice threshold; the envelope
   should follow. Trim/move/speed-change the source and retest. Mute, disable or
   delete it: music should return to its normal level. Test fades with ducking.
10. Try Slapback, Small room and Hall. Use a short click or spoken word followed
    by silence: echo should repeat at Time, Feedback should add decaying repeats,
    and reverb should leave a diffuse tail. Try low Distortion and Bitcrusher.
    Toggle each effect, undo/redo, split/copy, save/reopen, and export a movie.
    Listen from the beginning after seeking to compare the same effect history.
11. On a phone, short inspector, iPad and Mac, scroll to every control. Preset
   labels must fit, controls must stay inside the panel, and scrolling must
   remain usable. Check VoiceOver labels and large text.

## Automated checks

Run `bash Scripts/validate-audio-processing.sh` from the repository root.
It creates temporary mono/stereo tones, runs the production audio processing
tap through AVAssetReaderAudioMixOutput (the timeline export's audio path), and
checks neutral PCM preservation, pan, mute, fades, three EQ bands, both cuts,
bypass, compression, creative effects, sample count, preset stability at 8/44.1/48/96 kHz, and seek resets.

XCTest: AudioProcessingTests, AudioProcessingExportTests, AudioEditingTests, AudioFadeTests and
AudioPanelLayoutTests, AudioEffectsTests and AudioDuckingTests cover document compatibility, separation/split/copy/save,
validation, filter resets and narrow/wide panel layout. Layout tests attach PNGs.
AudioProcessingExportTests generates video and mono WAV fixtures, then checks
that the production movie export's AAC channels match preview, including compressor, ducking and creative effects.

## After this

1. Editable volume automation directly on the timeline, including editable ducking points.
2. A master output meter and limiter, plus loudness normalization for consistent delivery.
3. Noise reduction and voice isolation, after measuring quality, model size and device cost.
4. More creative presets and pitch/time effects, with device performance benchmarks.

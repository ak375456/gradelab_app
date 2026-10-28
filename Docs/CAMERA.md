# Camera capture

Home → Open Camera is available on iPhone and iPad. Mac Catalyst keeps its
existing import workflow. SIMPLE exposes looks and guides; PRO reveals exposure,
white balance and focus. These are capture controls, independent of StoreKit
Pro ownership. Everyone can preview camera LUTs, manual controls and all camera
scopes. **Recording requires an active GradeLab Pro entitlement**, including
1080p and original-look takes. Record remains tappable for free users and opens
the camera-recording paywall; no movie or recovery receipt is created. Both the
view model and capture boundary enforce this. Stopping/saving an existing take
stays available even if access expires. Purchase/restore closes the camera
paywall after entitlement verification; recording still requires another tap.
Existing editor export restrictions remain in force.
Camera controls, format/help panels, recording destinations, recovery/delete
actions, warnings, VoiceOver labels and the recording paywall are localized in
English, German, Spanish, Finnish, French, Italian, Japanese and Swedish. Camera
and microphone permission prompts use localized InfoPlist resources. Technical
codec/profile names, LUT identities and user/system microphone names are retained.
Indirect enum/slider/dashboard labels resolve through the catalog as well.
On phones, controls start collapsed. A live dashboard sits at the top of the
picture: Simple combines exposure and white balance; Pro exposes ISO, shutter,
white balance and focus separately. Readings come from the current device's
telemetry, including automatic changes. Tap a readout to open its controls;
starting a take collapses the drawer. The Simple/Pro selector changes the UI,
preserving any existing manual locks.
Exposure offers shutter speed or shutter angle, with 90°/180°/360° shortcuts.
A manual angle follows FPS changes; speed remains an absolute duration, clamped
to the sensor and frame period. 50 Hz/60 Hz flicker presets select whole lighting
cycles nearest 180° within those limits, lock exposure and preserve the current
ISO. Manual shutter changes clear the flicker preset; returning to Auto clears
both locks. Some LED/PWM sources can still flicker.
The small eye button hides all camera chrome, guides, focus markers and monitoring
overlays for a clean LUT preview. A restore button stays at the top right, with
a small red dot if a take is running. Capture, zoom and manual settings stay
unchanged; restoring controls also restores the previous monitoring settings.

The format summary opens a scrollable sheet with separate resolution, FPS,
color-profile, codec and stabilization sections. Profiles include Rec.709 SDR, 10-bit Rec.2020 HLG HDR, P3 D65 SDR, and
native Apple Log / Apple Log 2 when the selected lens exposes them. Unavailable
profiles and codecs stay dimmed with an explanation. Resolution includes native
720p, 1080p, 4K and exposed 4:3 sensor modes, with the actual pixel dimensions;
4:3 is not advertised as an uncropped sensor readout on devices that do not
expose one. HEVC/H.264 have Efficient, Balanced, High and Maximum bitrate targets
scaled by dimensions/FPS/depth. ProRes HQ, 422, LT and Proxy are exposed only
through AVFoundation's available encoders and use their own quality/bitrate.
A format switch never starts a recording.
Thermal pressure appears as a small amber thermometer. Tap it for the explanation.

Pinch the picture for continuous capture zoom, or use the lens/zoom presets.
Zoom uses AVFoundation's device zoom, so preview and original footage match.
Values are clamped to the selected format's hardware limits and a 10× displayed
maximum. A 0.5× stop requires an ultra-wide camera. Zoom on the active lens works
during recording; physical lens switches stay disabled until the take finishes.
Format changes and resume preserve zoom; changing lenses resets to that lens's
native field of view before applying a selected preset.

Guides offers thirds, quarters and golden-ratio grids, 1:1/4:5/16:9/2.39:1 frame
guides, a center crosshair and a 90% safe-area overlay. These stay inside the
actual picture. Frame guides are composition references and do not crop footage.
The optional horizon level uses Core Motion gravity corrected for capture
orientation, including the orientation locked during a take. The live line
follows the full measured roll; reference ticks align to the nearest portrait
or landscape axis, including when UI orientation is locked. The readout is the
deviation from that reference, turning green within 0.8° of level. It hides when
aimed almost straight up/down. Motion updates
stop when the level is off, controls are hidden, or the camera is inactive.
Focus and Guides both expose focus peaking with cyan/red/yellow/white and
sensitivity. A bounded source-detail filter highlights fine edges before the
creative LUT, independently of zebras/false colour. High sensitivity can also
mark noise; peaking is a focusing aid, not a sharpness guarantee. It never enters
recordings, scope measurements or exported frames.
The live histogram starts as a small card inside the picture. Tap it to expand
in place, choose a scope or change its intensity; collapse it with the corner
button. Expansion stays bounded to preserve the picture in portrait and landscape.
Guides → Live scope hides it entirely. All camera scopes are free to preview;
the editor's existing Pro-scope policy stays unchanged.

Finishing a take opens a destination sheet. **Edit in GradeLab** creates/opens
the editable project; **Save to Photos** copies the full-quality original with
add-only Photos permission and returns to the camera. With a preview look selected,
the sheet explains that Photos receives the original without that look. Saving
disables duplicate submissions and dismissal; a denied/failed save stays retryable.
**Decide later** or dismissing the sheet retains the take on Home for later.
Home's Recordings ready to open rows have Share and a 44-point Delete action.
Delete asks for confirmation, removes the selected receipt/original, and refreshes
the list. A stale receipt's original is preserved if a saved video/photo project
uses it. If either project library cannot be read, deletion stops with an error
and keeps the take retryable. Repeated deletes and stale UI actions are safe.

## Pipeline and ownership

- `Core/Camera/CameraCaptureController.swift` owns AVFoundation on one serial
  queue. `AVCaptureMovieFileOutput` records the original; a late-discarding
  `AVCaptureVideoDataOutput` feeds a bounded, thread-safe `PreviewFrameSource`.
  Lower-rate modes use preview-sized buffers beside the movie output. 4K50/60
  removes the movie output and uses a single full-resolution video data output
  plus `CameraSampleRecorder` (AVAssetWriter). Wide-color modes, ProRes and
  native 4:3 modes also use this single-stream graph. This avoids the iPhone 15's
  two-output hardware-cost overage while preserving native recording dimensions
  and live looks. Equivalent sensor modes prefer binned readouts, and the input's
  frame-duration override reserves bandwidth for the chosen FPS.
- The shared `MetalVideoRenderer` displays creative LUTs, saturation, vibrance, false colour and
  zebras. Saturation/vibrance use the editor's existing single GPU grade, range
  −100…100, and reset without removing the LUT. Their values are retained in
  the recording receipt/project; Photos receives the original. They freeze
  during a take together with the LUT. Guides measure the displayed image after its look. They never enter
  the recording. There is no separate camera grading implementation.
- `CameraPreviewConverter` converts only the HDR/P3 monitoring branch on
  the GPU, capped at a 1280-pixel long edge and 30 updates/sec, with one job
  in flight and a three-buffer pool. HDR remains half-float HLG signal for
  the existing HDR preview/scope transform. P3 is viewed through an explicit
  D65 P3 → Rec.709 conversion. Raw recording samples are delivered to the
  encoder first; slow monitoring never queues or blocks recording frames.
- Live scopes use the renderer's existing throttled, bounded GPU analyzer and
  scope renderer, including the preview display transform for Apple Log inputs.
  Monitoring overlays never enter their measurements or the original recording.
- Recording snapshots `GradeSettings` at the start. Look changes are disabled
  during the take, so a single editable grade accurately describes the take.
  Physical exposure, focus and white balance can still change during recording.
- The high-rate encoder receives original capture samples before any preview
  grade. AVFoundation supplies its codec/color settings and source format hints.
  The first video timestamp starts the take; earlier audio is skipped and video
  and audio retain their source timestamps. Bounded queues (12 video / 64 audio
  samples) absorb temporary encoder/interleaving backpressure, with nonblocking
  retries. Stop drains those queues before finalizing; sustained overload still
  stops explicitly, keeping the captured footage. Finalization is bounded, so a
  stalled writer cannot leave Record spinning indefinitely. Orientation is represented
  by the physically rotated source buffers, with matching encoder dimensions.
  Full-rate recording buffers are not discarded while the encoder warms up;
  frame duration is reasserted after output changes, and encoder settings name
  the selected source FPS explicitly.
- The destination sheet owns a stable recording item until dismissal. Only its
  dismissal callback clears the review and resumes a foreground camera; it does
  not depend on a transient sheet environment's scene phase. Partial-take warnings
  travel with the finished receipt and appear inside that sheet, avoiding an
  alert/sheet presentation collision. User recordings and receipts are preserved.
- `CameraRecordingStore` writes a receipt before starting. Original movies live
  in managed `Imports`; receipts use filenames to survive container relocation.
  Only choosing Edit asks the coordinator to create a project directly against
  that file, preserving the grade and source metadata, and open the editor.
  No copy/transcode runs.
- A successful project save clears the receipt and retains its project media.
  A confirmed Photos save clears the receipt and removes the local take, after
  Photos owns its copy. Failed or interrupted
  handoffs appear on Home with Retry/Open and Share Original. Retrying uses the
  same project UUID and preserves any already-saved edits. Partial files are
  retained; only empty failed captures can be discarded automatically.

## Capability boundaries

Modes follow the active lens's native sizes and supported 24/25/30/50/60 fps.
HLG and both Log profiles require 10-bit output and exclude H.264. Native Log
profiles are checked separately against `supportedColorSpaces` (Log 2 also
requires iOS 26+). A regular iPhone 15 exposes HDR HLG/P3 but no native Apple Log
or ProRes through this capture path. Codec availability is re-queried after
format changes; capability listings are not replaced by hardcoded model checks.
HLG recording explicitly uses Rec.2020/HLG/2020 tags and HEVC Main10. It does not
carry Dolby Vision metadata into graded delivery. Tagged ProRes HLG is accepted
by source preflight as well as HEVC HLG. P3 originals keep their wide primaries;
the editor and export explicitly request matching Rec.709 10-bit decoder output,
with a source notice explaining that conversion. PQ, untagged P3 and unrelated
wide gamuts remain blocked. RAW video, external disk capture and remote control
are not implemented.

Manual controls are clamped against the lens/format limits and frame period.
Fixed-focus lenses cannot enable manual focus. Rotation preserves manual
settings. Changing the physical lens returns to automatic exposure/WB/focus;
format changes preserve and clamp the current controls. Capture orientation locks during a take; the next
take follows the device. Front-camera footage and preview are both unmirrored.

Camera permission is required. Microphone permission is optional, with an
explicit No Audio meter state when disabled. Audio uses the active system
route; route changes while recording are reported. The built-in microphone
requests `AVCaptureDeviceInput.multichannelAudioMode = .stereo` when supported;
AVFoundation configures its microphone/polar pattern to match the camera.
Unsupported inputs fall back to mono, and external microphones retain their
native channel layout. The meter reads the movie
or sample-recorder connection's actual audio channels. Its compact dark panel
shows numbered lanes, green below −10 dBFS, yellow up to 0 dBFS and a red ceiling
zone. The nonlinear scale gives more room to readings near the ceiling. +3 is
display headroom; digital input still clips at 0 dBFS. Narrow panels show fewer
labels; tap the meter for a small popover with the full scale. Mono leaves the
second lane unavailable instead of duplicating it. No separate audio processor
changes recorded sound.

The storage readout shows approximate recording time for the current resolution,
FPS, codec, recording quality and profile. It includes audio/container overhead and the recorder's
200 MB reserve. After five seconds of a take it estimates from encoded file
growth. Variable bitrate and buffered writes mean the number is approximate;
tap it for details. Less than two minutes uses an amber readout.

Session startup/configuration is off the main thread. A background transition
stops and finishes the take with a bounded UIKit background task. Session
interruptions and errors are visible and retryable. Free-space checks prevent
starting below 250 MB, the recorder reserves 200 MB, and thermal warnings report
serious/critical pressure. Preview-drop counts are telemetry, not proof that
encoded recording frames were lost. Zero drops or crash recovery of every
partial MOV are not guaranteed.
Resume clears the frame-size cache even when the format has not changed, so
the first fresh buffer rebuilds the viewer. Runtime failures suspend the session
and clear record readiness; a 12-second preview watchdog ends stalled startup.

## Verification

`CameraSettingsTests`, `CameraRecordingStoreTests`, `CameraProjectHandoffTests`,
`CameraRecordingChoiceTests` and `CameraWorkspaceTests` cover control boundaries, rotated tap mapping,
receipt/footage retention, container relocation, original-byte preservation,
editable-look handoff, explicit destination choice, Photos retry/duplicate-save
handling, idempotent recovery, and compact/wide/large-text layouts. Photos tests
inject a save operation and never write to the user's library.
`CameraScopeSamplingTests` compares Apple Log/Log 2 histogram readings with the
actual preview shader after grading, and renders a known histogram to check
empty bins stay black and traces fill from the bottom.
`CameraRecordingAccessTests` checks free preview access, the recording paywall,
paid start, unrestricted stop, duplicate taps, closure during entitlement checks,
and clean-view restoration. Entitlements are injected in these tests; no purchase
is made. The device test also rejects an unauthorized capture before creating
any local take, then verifies the paid capture path with explicit test access.
`CameraMonitoringTests` covers angle/FPS conversion, flicker cycles, sensor
limits, horizon orientation and storage estimates. `CameraPeakingTests` renders
sharp/soft/flat fixtures through the actual preview shader and verifies shared
grading output ignores the peaking uniforms. Layout checks cover the expanded
controls on small phones, landscape and large text. The physical capture check
runs peaking and scopes alongside 4K60, verifies 50/60 Hz exposure durations,
angle persistence across formats and encoded file-growth telemetry.
Recording-store/handoff tests cover explicit pending-take deletion, preservation
of project media and unrelated takes, malformed paths and unreadable libraries.
Keep existing colour pipeline, scopes/LUT and project-store regressions green.
`CameraColorFormatTests` checks bitrate/estimate consistency, ProRes variants,
10-bit HLG monitoring values, and a tagged non-neutral P3 fixture against the
actual AVFoundation Rec.709 edit/export conversion. The expanded physical
format test verifies supported profile movies, color tags, dimensions, frame
cadence, editable color receipts and source preflight. Layout snapshots cover
the creative sliders and expanded format panel.
`CameraLocalizationTests` checks all camera/paywall keys in the compiled language
bundles, both permission prompts and typed interpolation for audio and remaining
time. String-catalog placeholder validation covers all seven translated locales.
Use `SWIFT_EMIT_LOC_STRINGS=NO` for builds.
`CameraCaptureDeviceTests` checks real 4K60 HEVC switching, continuous preview and
live scope analysis during capture,
suspend/resume, switching back to 1080p/4K50, and portrait/landscape one-second
movies' dimensions, frame timestamps, codec and audio on a physical device with existing camera permission. The test
take is stored in a unique temporary folder and deleted after validation. It
skips simulators or denied camera access. With the iPhone's built-in microphone,
it also requires two live meter channels and decodes 1080p/4K60 recordings to
verify two distinct PCM channels rather than a duplicated mono stream. It applies
2× capture zoom, checks it survives a format switch, zooms to 2.5× during 4K60,
and switches to the physical ultra-wide lens when present.
`CameraWorkflowDeviceTests` hosts the actual full-size CameraView with a LUT,
peaking, scopes and level enabled. It records/stops two 1080p30 and two 4K60 takes,
checks the destination sheet, returns to a fresh preview after each dismissal,
and validates movie dimensions, duration and encoded frame cadence. This covers
the UI/capture lifecycle and preview workload missed by capture-only tests.

Physical-device acceptance is still required:

1. iPhone 15 and iPad: grant/deny camera and microphone independently; retry
   after changing Settings. Confirm silent capture is unmistakable.
2. Check portrait, both landscape orientations, large text and one-handed
   controls. Tap within the actual image to focus; letterbox taps do nothing.
3. Select each physical lens, format/FPS and available codec. Confirm unsupported
   combinations and fixed-focus/manual restrictions. On a Pro device, verify
   Apple Log really records 10-bit Log with valid tags and reopens correctly.
4. Compare a chosen look live and in the editor/export. Confirm original files
   contain no LUT, zebras or guides. Check native exposure and WB locks actually
   hold, and rotating before a take preserves them.
5. Verify the live audio meter responds before/during recording and matches
   playback. Plug/unplug external audio and check the route-change notice.
6. Record short and 20–30 minute takes in supported modes; inspect A/V sync,
   frame timing, heat, battery and low-storage stops. UI compile/simulator tests
   cannot establish sensor or encoder reliability.
7. Background, lock, interrupt with a call, and relaunch. Finished footage should
   open; unfinished imports must remain recoverable/shareable on Home. Cancel
   camera startup and return Home without leaking the session or idle timer.
8. Stop a take: verify the destination sheet appears before any project opens.
   Choose Edit, Save to Photos, and Decide later on separate takes. Deny Photos,
   retry after Settings, and verify the full-quality original arrives only once.
   Expand/collapse scopes, open controls, and tap the picture to focus; scope
   controls must consume their own taps without triggering a focus gesture.

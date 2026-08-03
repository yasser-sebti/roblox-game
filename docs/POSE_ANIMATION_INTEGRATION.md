# R15 Pose Animation V3 Integration

This guide is the runtime contract for animation text exported by the local R15 Pose Tuner. The tuner itself remains an Edit-mode plugin and is not part of the published game.

## Format

`R15_POSE_ANIMATION_V3` returns a Luau table containing `Duration`, `PlaybackSpeed`, `FPS`, `Loop`, `Interpolation`, `AutoKey`, and an ordered `Keyframes` array. Each key has a stable `Id`, explicit `Time`, outgoing `EasingStyle` and `EasingDirection`, per-key `Smooth` and `GroundLock` flags, and a sparse `Values` map.

Every pose value is an exact 12-component `CFrame`: three translation components followed by the 3×3 rotation matrix. Do not convert exported values through Euler angles; doing so loses precision and can introduce rotation discontinuities.

## Export files and completeness

**View Anim TXT**, **Save .TXT**, and **Save .LUAU** all use the same complete V3 serializer. The two file extensions contain identical valid Luau data; `.luau` is intended for direct module use, while `.txt` is convenient for sharing and inspection. Files are written to `C:\MyRobloxGame\pose-exports` by the local helper started through `run-pose-tuner.bat`.

Before a whole-animation view or file export is accepted, the tuner parses its generated text back into a document and compares it with the live document. The audit covers:

- `RigType` and format `Version`
- duration, playback speed, FPS, looping, interpolation, and Auto-Key
- every key ID and exact key time
- outgoing easing style and direction
- per-key Smooth and Ground Lock values
- the presence of every sparse joint key
- all 12 numeric components of every keyed `Motor6D.Transform`

Editor-only state such as the selected dummy, selected keys, onion-skin visibility, snapping preferences, camera position, and calculated preview grounding offset is intentionally not animation data and is therefore not exported.

Sparse keys mean a joint may be absent from a key:

- Before that joint's first key, hold its first keyed value.
- Between two keys for that joint, hold the earlier value in Step mode or interpolate using the earlier key's outgoing easing in Smooth mode.
- After its final key, hold the final value.
- A joint never keyed remains `CFrame.identity`.

An empty master key is valid. It can act as a timing/easing or Ground Lock marker even when no joint differs from the neutral pose. **Apply Pose** stores only joints whose exact transform differs from `CFrame.identity`; **Key Pose** stores all joints, and **Key Neutral** explicitly stores identity transforms for all joints.

The supported easing styles are intentionally limited to Linear, Sine, Quad, and Cubic, with In, Out, and InOut directions. When the outgoing key has `Smooth = true`, evaluate its easing and use the previous/current/next/following keyed values to form time-aware cubic Hermite tangents. For internal connected segments, preserve boundary velocity while applying the easing primarily inside the segment; this prevents InOut from causing an artificial stop at every key. Re-orthonormalize the interpolated CFrame basis before applying it. When `Smooth = false`, hold the original outgoing pose until the next key. Toggling Smooth never rewrites or bakes the stored CFrames, so disabling it restores the clean step animation exactly.

## Runtime application

Cache the R15 `Motor6D` objects once when the character spawns. At the animation update rate, evaluate each joint's transform and apply it through `Motor6D.Transform`. The exported values are additive transforms relative to the rig's authored rest joints; they are not world-space part transforms and must not replace `C0` in the live game.

When combining an exported animation with procedural locomotion, keep separate contributions and blend deliberately. A practical order is:

1. Evaluate the authored V3 pose.
2. Blend its state weight during entry/exit.
3. Add or blend procedural camera-follow, terrain IK, foot orientation, and impact corrections only on joints the procedural system owns.
4. Write each final `Motor6D.Transform` once per frame.

Avoid having two systems write the same joint independently. If locomotion must retain ownership of a leg, use the authored pose as the base target and apply IK as the final correction.

## Timing and playback

Scale elapsed time by `PlaybackSpeed`. For looping animations, wrap to the earliest authored key rather than assuming the first key occurs at zero. Empty time before the earliest animation key evaluates as that earliest complete pose. `FPS` is the authoring and snapping rate; runtime evaluation can still run every rendered frame.

`GroundLock` evaluates to `0` or `1` at each master key and blends across a segment only when that outgoing key has `Smooth = true`. With Smooth off it switches exactly at the next key. The smooth blend uses the same neighbor-aware easing and remains clamped between zero and one. Before the first key and after the last key, the nearest key's value is held. In the tuner this blend applies a non-destructive vertical correction against the lowest rotated body-part extent. A runtime that wants the same grounded result must evaluate the blend and perform its own character/terrain grounding solve; do not interpret it as a joint CFrame.

## What is not exported

The tuner's calculated Ground Lock vertical offset is preview-only; only the per-key boolean instruction is exported. First Person preview is also preview-only: its camera offset, hidden head/accessories, mouse-look state, and Studio camera settings are never animation data.

## Validation checklist

- Test the exact R15 body proportions used by the game.
- Verify the animation before the first key, between sparse keys, after the final key, and while looping.
- Test each supported easing style and verify velocity remains continuous through connected internal keys.
- Confirm unkeyed joints remain neutral and procedural locomotion does not double-write joints.
- Confirm Ground Lock and First Person preview do not affect a round-trip export/import.

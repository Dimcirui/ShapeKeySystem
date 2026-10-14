# Onimusha: Way of the Sword — what the port found, and how it maps onto the adapter design

Branch `onimusha-port` runs ShapeKeySystem in Onimusha with a small game seam (`Core/Game.lua`).
It was built before `docs/plans/multi-game-adapter.md` and does not follow its structure (the seam
lives in Core, Guard tests the game id, the Onimusha signals are an overlay). Everything below was
measured in game with read-only probes on kevin's machine (Maya + Bunny Heart Sailor replacing
Musashi), and answers the open questions of the adapter doc's §8 for Onimusha.

## Facts

**Game and player**
- `reframework:get_game_name()` → `onimusha_wots`.
- Player: `app.PlayerManager:getControllingPlayerInfo():get_Object()` (falls back to
  `get_ControllingPlayer`) → `Player_00`. No `getMasterPlayer`, no `app.DemoMediator`.
- Children of `Player_00` seen: `Body`, `Head`, `Hair`, `Gauntlet` (ch001_00_60), `Cloak`,
  `Amulet`, `AmuletSub`, `Gm800_*` (swords/sheaths), and `OniHead` for the Oni form.
  Cutscenes animate the same `Player_00/Head`.

**Face**
- There are no fcParam joints and no `bsControl` joints. The face is a bone rig: the face mesh's
  skeleton holds `Face`, `Head_end`, `teeth_base`, `eye_Lt`, `eye_Rt` and 206 `face_joint*`
  (parents `Head_end` / `Face`; `Head_end` has the same orientation as `Head`).
- Facial animation (idle loop, talking, combat, cutscenes) only **translates** the `face_joint*`
  bones; their rotation stays at the bind pose. About 200 of them move. Typical travel in the Head's
  frame (+x = the face's left, +y up, +z forward): upper lids 8–9 mm per blink, chin 13 mm and lower
  lip 22 mm at a wide-open mouth, brows 4–6 mm, mouth corners 5–6 mm.
- The eyes rotate (`eye_Lt` / `eye_Rt`, local X = pitch, Y = yaw) in the same convention as Wilds,
  so `quat_to_yaw_pitch` works unchanged. They swing wider than in Wilds (raw yaw up to about ±35°).
- Musashi's idle blinks are frequent and slow: 66 in 3 minutes, a median 0.3 s each.

**Meshes and blend shapes**
- `via.render.Mesh` has **no `getBlendShapeChannelName`**. It has `get_ChannelNameHash`, a
  `System.UInt32[]` whose elements read as numbers only through `ToString`. Each value is murmur3
  x86_32 of the channel's name in UTF-16LE, seed 0xFFFFFFFF (all 29 of Maya's keys matched, in
  channel order). Other blend-shape methods present: `get_ChannelWeightList`, `get_BlendShapeLOD`,
  `get_UseBlendShapeNormal`, `set_BlendShapeChannelWeightCount`, and the usual weight getters/setters.
- A face mesh can be its own part: Maya's keys sit on the `Head` mesh itself. Weights written to
  them with `setBlendShapeChannelWeightParam` in LateUpdateBehavior stick (349 of 349 frames kept)
  and render. `app.FacialController` sits on the player's Head but does not touch channels it does
  not know.
- NPC faces are pure blend-shape faces (400+ channels, `app.FacialController`, no face joints); the
  game rewrites their weights every frame, so writes to them never show.
- Mod meshes with blend shapes for Onimusha are written by RE-Mesh-Editor-BlendShape (`ONIWOTS`,
  Keep Custom Normals); verified in game.

**Lifecycle**
- No cutscene or equipment-rebuild hooks were needed. The player disappears for a moment on loads
  (no controlling player); the Head / OniHead objects can be swapped for new ones under the same
  name, which the port catches by including the object's address in the children signature.

## The port's seam, mapped onto the adapter interface

| `onimusha-port` (`Core/Game.lua`) | adapter design |
|---|---|
| `master_root()` | `A.primary_root()` |
| gate: "no player" → release without a last write | `A.gate(frame)` (no kind for "gone" yet: the meshes may already be torn down, so no zeroing) |
| `is_face(name)` (`Head` / `OniHead`) + `face_markers` (`face_joint340` or `Face`) | `A.is_face(tr)` |
| `face_is_part` (one rig per face; the part is the face's own mesh) | `A.parts(root)` returning the faces, plus "face and part may be the same node" |
| `child_key(name, tr)` (name@address) | none yet: a way to notice an object swapped under the same name |
| `eyes = {eye_Lt, eye_Rt}` | `A.eye_joints(face)` |
| `signals_onimusha.json` overlay; every Wilds name stays declared, unwired = reads 0 | `builtin/onimusha_wots/signals.json` with `"raw": null` for the unwired names (D6); the bone entries carry `rest_mm` / `full_mm` (D10's `lo` / `hi`) |
| `has_fcparams = false` | `caps.expression` with `A.raw` / `A.bind` / `A.read` over face_joint translations |
| `hooks = false` (no cutscene, equip, menu, guild card or input hooks) | `caps.cutscene / preview / input_block = false` |
| `Scene.channel_names`: names from `get_ChannelNameHash` + murmur3 of every known name | stays in Core (`via.*` calls) |

The calibrated bone signals (bone, axis, sign, rest, full, deadzone; measured on 3 min of idle,
Musashi talking in a cutscene and a boss fight) are in
`reframework/data/ShapeKeySystem/builtin/signals_onimusha.json`. The mouth-corner-up range is a
guess: the recordings hold almost no smiles.

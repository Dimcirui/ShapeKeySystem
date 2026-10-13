# vrc_profiles — builtin expression profiles for VRChat avatars

Builds `builtin/profiles/<id>.json` for VRChat base avatars from the face mesh (`Body`) shape keys,
with every mapping checked against what the key actually does in Blender.

1. **Find base avatars**: `python -I fbxkeys.py <VRC folder> scan.json` lists every FBX's meshes and
   shape-key counts. A base avatar has a `Body` mesh with hundreds of keys and a `Body_base`
   (body) mesh; hair / clothing FBXs have a few keys on other meshes. Base FBXs inside archives:
   `7z e -o ext/<tag> <archive> <path inside>` (`ext/` is gitignored).
2. **Measure**: run `blender_probe.py` in Blender (edit `AVATARS` first). It writes `probe/<tag>.json`
   (gitignored) with per-key side, height, direction and inner / outer motion.
3. **Inspect**: `python -I q.py <tag> <regex>...` prints the measurements, e.g.
   `q.py manuka "^brow_.*_L$"`. `+x` = share of motion on the character's left; `in/out` =
   vertical (`z`) and outward (`o`) motion of the half of the moved verts nearer / farther from
   the midline (brow: sad = inner z+, angry = inner z−; mouth: smile = outer z+, wide = outer o+).
4. **Map**: one entry per profile in `specs.py` (slot -> key names; `any` fallbacks for family
   members that spell keys differently). `gen.py` turns it into profiles with the same signal
   templates as `eku.json` / `milltina.json` and measurement notes.
5. **Check**: `python -I check.py <profile.json> <tag>...` flags keys whose measured side or
   direction contradicts their signal. `tests/tests_mmd.lua` checks that each face in
   `tests/vrc_faces.json` is auto-matched to its own profile.

Gaze: SKS yaw +1 = eye turned to the character's own left (Shinano, verified in game). A key that
moves the iris to +X gets yaw +1, whatever its name says.

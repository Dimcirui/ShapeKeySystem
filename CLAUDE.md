# ShapeKeySystem — working notes

REFramework Lua plugin for MH Wilds. Design docs: `docs/plans/shape-key-system.md` (architecture,
milestones) and `docs/plans/shape-key-system-api.md` (UI ↔ backend contract, commands, file formats).

## Workflow
- This repo is the source of truth. Edit here, then `tools\deploy.ps1` to copy into the game
  (`E:\Program\Steam\steamapps\common\MonsterHunterWilds\reframework`). Before editing, run
  `tools\deploy.ps1 -Check`; if the game copy has newer edits, `-Pull` them first.
- Offline harness: `cd tests; python run.py` — every group prints `... FAILS: n`. Add checks to the
  matching `tests_*.lua` when changing behaviour. Two gaze checks in `tests.lua` were already failing
  at migration (2026-10-10, after the eye yaw/pitch sign fix).
- Player data under `reframework/data/ShapeKeySystem` (settings.json, user/, mods/, trail.log) is
  gitignored and never deployed.

## Writing
- Comments, commit messages, release notes and issue comments follow `docs/writing/`
  (index: `docs/writing/README.md`). Read the guideline for the kind of text before writing it.

## REFramework rules learned the hard way
- `require` resolves dotted names under autorun (`A.B.C` included), but only while scripts load —
  require everything at load time, never lazily from a frame/d2d callback.
- A Lua integer passed to a `System.Single` parameter arrives as raw bits (1 -> 1.4e-45): always
  `v + 0.0` before engine calls.
- Blendshape writes only in `LateUpdateBehavior`, only after the mesh weight buffer exists, and
  never hold engine object references across part rebuilds / cutscene teardown (`Guard.lua`).
- Shipped features must not depend on REFramework.NET (C#); C# plugins are for exploration probes
  only. Native C plugins (reframework/plugins/*.dll) are fine where Lua cannot do the job (sockets).
- Never conflict with ArmorVariantManager: default hotkey Delete (Home = AVM, End = game pause),
  share AVM's input-blocker globals, do not replace the d2d global.

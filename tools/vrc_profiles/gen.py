"""Generate SKS builtin profiles for VRChat avatars from a slot spec + Blender probe data.
python -I gen.py [out_dir]   (default: the repo's builtin/profiles)
Slot spec values:
  ("L", "R")                 split keys (left / right of the character)
  ("L", "R", ["altL"], ["altR"])   split keys with 'any' fallbacks (best first)
  "name" or ("name", ["alt"])      one combined key: left/right signals averaged
Gaze slots take ("L", "R") for per-eye keys or "name" for a both-eyes key.
Optional per-slot overrides in NOTE[slot] / GUESS[slot]; spec["extra"] adds whole channels
(name, group, node, note) after the slots.
English (name_en, description_en, note_en) comes from tools/i18n/data_en.py; a note sentence it
does not know stops the run (add it there).
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "probe")
sys.path.insert(0, os.path.join(HERE, "..", "i18n"))
from data_en import PROFILE_EN, note_en  # noqa: E402

# slot -> (group, signal base, always guessed, description of the expected deformation)
SLOTS = {
    "brow_outer": ("brow", "browOuterUp", False, "眉毛上移"),
    "brow_down":  ("brow", "browDown", False, "眉毛下压"),
    "brow_inner": ("brow", "browInnerUp", False, "眉头上提"),
    "brow_bring": ("brow", "browBring", False, "眉头下压（皱眉）"),
    "blink":      ("eye", "blink", False, "闭眼"),
    "squint":     ("eye", "eyeSquint", False, "上眼睑下降、眼裂缩小"),
    "wide":       ("eye", "eyeWide", True, "睁大眼"),
    "lower_up":   ("eye", "cheekSquint", True, "下眼睑上提（笑眼下睑分量）"),
    "puff":       ("nose_cheek", "puff", False, "脸颊鼓起"),
    "jaw":        ("mouth", "jawOpen", False, "张嘴"),
    "funnel":     ("mouth", "funnel", True, "u 口型（嘴唇收拢）"),
    "smile":      ("mouth", "smile", False, "嘴角上扬"),
    "frown":      ("mouth", "frown", False, "嘴角下垂"),
    "stretch":    ("mouth", "stretch", False, "嘴角向外、嘴变宽"),
    "narrow":     ("mouth", "funnelTogether", True, "嘴角向内、嘴变窄"),
    "press":      ("mouth", "press", True, "抿嘴（嘴角收紧）"),
    "mouth_left": ("mouth", "mouthMove.left", True, "嘴整体移向角色左侧"),
    "mouth_right": ("mouth", "mouthMove.right", True, "嘴整体移向角色右侧"),
    "mouth_up":   ("mouth", "mouthMove.up", True, "嘴整体上移"),
    "mouth_down": ("mouth", "mouthMove.down", True, "嘴整体下移"),
    "gaze_up":    ("gaze", ("pitch", 1), False, "虹膜上移"),
    "gaze_down":  ("gaze", ("pitch", -1), False, "虹膜下移"),
    "gaze_left":  ("gaze", ("yaw", 1), False, "虹膜移向角色左侧"),
    "gaze_right": ("gaze", ("yaw", -1), False, "虹膜移向角色右侧"),
}
ORDER = list(SLOTS)
GAZE_NOTE = ("视线方向按 Shinano 游戏实测换算：虹膜移向角色自身左侧(+X) 对应 yaw +1。")


def side_node(slot, side):
    base = SLOTS[slot][1]
    if slot == "smile":
        return {"min": [{"const": 1}, {"sum": [{"s": "smile." + side}, {"s": "smileMinor." + side, "k": 0.5}]}]}
    if base.startswith("mouthMove") or slot == "jaw":
        return {"s": base}
    return {"s": base + "." + side}


def joint_node(slot):
    base = SLOTS[slot][1]
    if slot == "smile":
        return {"min": [{"const": 1}, {"sum": [{"s": "smile.L", "k": 0.5}, {"s": "smile.R", "k": 0.5},
                                               {"s": "smileMinor.L", "k": 0.25}, {"s": "smileMinor.R", "k": 0.25}]}]}
    if base.startswith("mouthMove") or slot == "jaw":
        return {"s": base}
    return {"sum": [{"s": base + ".L", "k": 0.5}, {"s": base + ".R", "k": 0.5}]}


# slot -> bone signal (builtin/signals.json). Gameplay emotes move the face's bones, not the
# fcParams (in-game probes, 2026-10-13), so these keys take the largest of them. Emote blinks
# close (and widen) the eyes with the upper-lid bones while the eye fcParams stay 0; laughs open
# the mouth with the lower lip while the chin stays inside jawDrop's deadzone.
BONE = {
    "brow_outer": "browRaise", "brow_down": "browLower", "brow_bring": "browInnerDown",
    "blink": "eyeClose", "wide": "eyeWiden", "lower_up": "cheekRaise", "jaw": ["jawDrop", "lowerLipDrop"],
    "smile": "mouthCornerUp", "frown": "mouthCornerDown", "stretch": "mouthCornerOut",
}
BONE_NOTE = "游戏动作表情由面部骨骼驱动：同时读骨骼信号 {}，取较大者"


def with_bone(slot, node, side=None):
    """(node, note sentence) -> node maxed with the slot's bone signal(s), or (node, None)"""
    b = BONE.get(slot)
    if not b:
        return node, None
    bones, names = [], []
    for b in (b if isinstance(b, list) else [b]):
        if slot == "jaw":
            bones.append({"s": b}); names.append(b)
        elif side:
            bones.append({"s": b + "." + side}); names.append(b + "." + side)
        else:
            bones.append({"sum": [{"s": b + ".L", "k": 0.5}, {"s": b + ".R", "k": 0.5}]}); names.append(f"{b}.L / {b}.R")
    return {"max": [node] + bones}, BONE_NOTE.format(" / ".join(names))


def gaze_node(slot, eye=None):
    axis, sign = SLOTS[slot][1]
    if eye:
        return {"eye": eye, "axis": axis, "sign": sign}
    return {"sum": [{"eye": "L", "axis": axis, "sign": sign, "k": 0.5},
                    {"eye": "R", "axis": axis, "sign": sign, "k": 0.5}]}


def measure(probes, key):
    """short description of the measured deformation of `key` on the first probe that has it"""
    for tag, p in probes:
        v = p["keys"].get(key)
        if v is None:
            continue
        if len(v) == 1:
            return tag, "Blender 测量：无形变"
        mx = v[1] * 1000
        return tag, f"最大位移 {mx:.1f}mm"
    return None, None


def build(spec, probes):
    chans = []
    for slot in ORDER:
        if slot not in spec["slots"]:
            continue
        val = spec["slots"][slot]
        group, _, always_guess, desc = SLOTS[slot]
        guessed = always_guess or slot in spec.get("guess", ())
        extra = spec.get("notes", {}).get(slot, "")
        is_gaze = group == "gaze"
        entries = []
        if isinstance(val, tuple) and len(val) >= 2 and isinstance(val[1], str):
            l, r = val[0], val[1]
            alt_l = val[2] if len(val) > 2 else None
            alt_r = val[3] if len(val) > 3 else None
            for side, name, alt in (("L", l, alt_l), ("R", r, alt_r)):
                node, bone_note = (gaze_node(slot, side), None) if is_gaze else with_bone(slot, side_node(slot, side), side)
                entries.append((name, alt, node, bone_note,
                                desc + ("" if is_gaze else f"（{'左' if side == 'L' else '右'}侧）")))
        else:
            name, alt = (val, None) if isinstance(val, str) else (val[0], val[1])
            node, bone_note = (gaze_node(slot), None) if is_gaze else with_bone(slot, joint_node(slot))
            joint_desc = desc
            if not is_gaze and slot not in ("jaw",) and not SLOTS[slot][1].startswith("mouthMove"):
                joint_desc += "；左右合一的键，左右信号各取一半"
            entries.append((name, alt, node, bone_note, joint_desc))
        for name, alt, node, bone_note, d in entries:
            tag, m = measure(probes, name)
            note = d
            if m:
                note += f"。{m}（{tag}）"
            if alt:
                note += f"。网格里没有 {name} 时用 {' / '.join(alt)}"
            if is_gaze:
                note += "。" + GAZE_NOTE
            if extra:
                note += "。" + extra
            if bone_note:
                note += "。" + bone_note
            ch = {"name": name, "group": group}
            if alt:
                ch["any"] = list(alt)
            if is_gaze:
                ch["gaze_set"] = "look"
            ch.update(node)
            if guessed:
                ch["guessed"] = True
            ch["note"] = note
            ch["note_en"] = note_en(note)
            chans.append(ch)
    # spec["extra"]: channels outside the slot templates, written as given (node and note)
    for ex in spec.get("extra", ()):
        ch = dict(ex)
        ch["note_en"] = note_en(ch["note"])
        chans.append(ch)
    return chans


def dump(spec, chans, out_dir):
    name_en, desc_en = PROFILE_EN[spec["id"]]
    head = {"schema": "sks.profile/1", "id": spec["id"], "name": spec["name"], "name_en": name_en,
            "description": spec["description"], "description_en": desc_en, "aliases": []}
    lines = ["{"]
    for k, v in head.items():
        lines.append(f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)},")
    lines.append('  "channels": [')
    for i, ch in enumerate(chans):
        lines.append("    " + json.dumps(ch, ensure_ascii=False) + ("," if i < len(chans) - 1 else ""))
    lines.append("  ]")
    lines.append("}")
    path = os.path.join(out_dir, spec["id"] + ".json")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    json.load(open(path, encoding="utf-8"))
    return path


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, "..", "..", "reframework", "data", "ShapeKeySystem", "builtin", "profiles")
    from specs import SPECS
    for spec in SPECS:
        probes = [(t, json.load(open(os.path.join(PROBE, t + ".json"), encoding="utf-8"))) for t in spec["probes"]]
        chans = build(spec, probes)
        # every key named in the spec must exist on at least one probed mesh
        for ch in chans:
            names = [ch["name"]] + ch.get("any", [])
            if not any(n in p["keys"] for n in names for _, p in probes):
                raise SystemExit(f"{spec['id']}: no probed mesh has {names}")
        print(dump(spec, chans, out_dir), len(chans))


if __name__ == "__main__":
    sys.path.insert(0, HERE)
    main()

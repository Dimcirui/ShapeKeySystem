"""Derive the MH Rise bone-signal calibration from face joint recordings.

Input: SKS native-signals recordings (`native_signals_mhrise_*.json`, from the 原生信号诊断与录制 card on the
settings and debug page; each sample has the face_base joints and `motion` = "bank/id" of face Motion layer 1), or CSVs
from the exploration probe (columns `face:<joint>.<px..qw>`, optional `layer1` = "bank/id/frame").
Recordings stay local; only the derived table is shipped.

Each rule names a joint, a kind and a semantic direction in the joint's local frame (all Rise face
frames are aligned with Head_00: +x character left, +y up, +z forward). Everything else comes from data:
- neutral: per-component median over idle frames (idle recordings, or layer1 motion 12/30 and 12/1);
- axis: mean displacement of the frames beyond the idle range within 60 degrees of the semantic direction;
- lo: largest idle projection (the breathing loop never triggers a key);
- hi: largest projection over all frames; mirrored L_/R_ rules share the wider lo and hi.
Rules with fewer than MIN_FRAMES directional frames or a range below MIN_RANGE are dropped and the key stays unavailable (signals.json raw null).

usage: python -I tools/rise_calibrate.py --idle a.csv [--idle b.csv] rec1.csv ... -o face.json
       [--signals builtin/re4/signals.json builtin/mhrise/signals.json]
"""
import argparse, csv, json, math

MIN_RANGE = {"pos": 0.5, "rot": 1.0}   # millimetres / degrees
MIN_FRAMES = 30                        # about half a second of a held pose
MIN_COS = 0.5                          # a frame counts for a direction within 60 degrees of it
IDLE_MOTIONS = {"12/30", "12/1"}

# key, channel name, bone, kind, semantic direction
RULES = [
    ("eyeBlinkLeft", "L_Up_Eyelib.down", "L_Up_Eyelib", "pos", (0, -1, 0)),
    ("eyeBlinkRight", "R_Up_Eyelib.down", "R_Up_Eyelib", "pos", (0, -1, 0)),
    ("eyeWideLeft", "L_Up_Eyelib.up", "L_Up_Eyelib", "pos", (0, 1, 0)),
    ("eyeWideRight", "R_Up_Eyelib.up", "R_Up_Eyelib", "pos", (0, 1, 0)),
    ("eyeSquintLeft", "L_Lo_Eyelib.up", "L_Lo_Eyelib", "pos", (0, 1, 0)),
    ("eyeSquintRight", "R_Lo_Eyelib.up", "R_Lo_Eyelib", "pos", (0, 1, 0)),
    ("browInnerUp", "L_Brow_00.up", "L_Brow_00", "pos", (0, 1, 0)),
    ("browInnerUp", "R_Brow_00.up", "R_Brow_00", "pos", (0, 1, 0)),
    ("browDownLeft", "L_Brow_00.down", "L_Brow_00", "pos", (0, -1, 0)),
    ("browDownRight", "R_Brow_00.down", "R_Brow_00", "pos", (0, -1, 0)),
    ("browOuterUpLeft", "L_Brow_01.up", "L_Brow_01", "pos", (0, 1, 0)),
    ("browOuterUpRight", "R_Brow_01.up", "R_Brow_01", "pos", (0, 1, 0)),
    ("noseSneerLeft", "L_Nose.up", "L_Nose", "pos", (0, 1, 0)),
    ("noseSneerRight", "R_Nose.up", "R_Nose", "pos", (0, 1, 0)),
    ("cheekSquintLeft", "L_Cheek_00.up", "L_Cheek_00", "pos", (0, 1, 0)),
    ("cheekSquintRight", "R_Cheek_00.up", "R_Cheek_00", "pos", (0, 1, 0)),
    ("jawOpen", "Jaw_00.open", "Jaw_00", "rot", (1, 0, 0)),
    ("mouthSmileLeft", "L_Corner_Mouth.up", "L_Corner_Mouth", "pos", (0, 1, 0)),
    ("mouthSmileRight", "R_Corner_Mouth.up", "R_Corner_Mouth", "pos", (0, 1, 0)),
    ("mouthFrownLeft", "L_Corner_Mouth.down", "L_Corner_Mouth", "pos", (0, -1, 0)),
    ("mouthFrownRight", "R_Corner_Mouth.down", "R_Corner_Mouth", "pos", (0, -1, 0)),
    ("mouthStretchLeft", "L_Corner_Mouth.out", "L_Corner_Mouth", "pos", (1, 0, 0)),
    ("mouthStretchRight", "R_Corner_Mouth.out", "R_Corner_Mouth", "pos", (-1, 0, 0)),
    ("mouthPucker", "L_Corner_Mouth.in", "L_Corner_Mouth", "pos", (-1, 0, 1)),
    ("mouthPucker", "R_Corner_Mouth.in", "R_Corner_Mouth", "pos", (1, 0, 1)),
    ("mouthUpperUpLeft", "L_Up_Mouth_01.up", "L_Up_Mouth_01", "pos", (0, 1, 0)),
    ("mouthUpperUpRight", "R_Up_Mouth_01.up", "R_Up_Mouth_01", "pos", (0, 1, 0)),
    ("mouthLowerDownLeft", "L_Lo_Mouth_01.down", "L_Lo_Mouth_01", "pos", (0, -1, 0)),
    ("mouthLowerDownRight", "R_Lo_Mouth_01.down", "R_Lo_Mouth_01", "pos", (0, -1, 0)),
]
# two corners share mouthPucker, two inner brows share browInnerUp: each contributes half
SHARED = {"mouthPucker": 0.5, "browInnerUp": 0.5}


KEYS = ("px", "py", "pz", "qx", "qy", "qz", "qw")


def load(path):
    if path.endswith(".json"):   # SKS native-signals recording
        with open(path, encoding="utf-8") as f:
            rec = json.load(f)
        if rec.get("schema") != "sks.native-signals/1" or rec.get("game") != "mhrise":
            raise SystemExit(f"{path}: not an MH Rise native-signals recording")
        return [({name: dict(zip(KEYS, v)) for name, v in s["values"].get("joints", {}).items()},
                 s["values"].get("motion")) for s in rec["samples"]]
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    head, body = rows[0], rows[1:]
    col = {n: i for i, n in enumerate(head)}
    frames = []
    for r in body:
        joints = {}
        for n, i in col.items():
            if not n.startswith("face:") or not r[i]:
                continue
            joint, comp = n[5:].rsplit(".", 1)
            joints.setdefault(joint, {})[comp] = float(r[i])
        layer = r[col["layer1"]].rsplit("/", 1)[0] if "layer1" in col else None
        frames.append((joints, layer))
    return frames


def pose(j):
    return [j["px"], j["py"], j["pz"]], [j["qx"], j["qy"], j["qz"], j["qw"]]


def median(v):
    v = sorted(v)
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def delta(kind, neutral, p, q):
    """Displacement in mm, or rotation vector in degrees (same convention as BoneSignals.measure)."""
    if kind == "pos":
        return [(p[i] - neutral[i]) * 1000 for i in range(3)]
    ax, ay, az, aw = -neutral[3], -neutral[4], -neutral[5], neutral[6]
    bx, by, bz, bw = q
    x = aw * bx + ax * bw + ay * bz - az * by
    y = aw * by - ax * bz + ay * bw + az * bx
    z = aw * bz + ax * by - ay * bx + az * bw
    w = aw * bw - ax * bx - ay * by - az * bz
    if w < 0:
        x, y, z, w = -x, -y, -z, -w
    length = math.sqrt(x * x + y * y + z * z)
    if length < 1e-9:
        return [0.0, 0.0, 0.0]
    angle = math.degrees(2 * math.atan2(length, w))
    return [x / length * angle, y / length * angle, z / length * angle]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle", action="append", default=[], help="recording that is idle throughout")
    ap.add_argument("recordings", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--signals", nargs=2, metavar=("TEMPLATE", "OUT"),
                    help="write a signal dictionary listing TEMPLATE's generic names (D6), raw null where no rule")
    args = ap.parse_args()

    idle, every = [], []
    for path in args.idle:
        frames = load(path)
        idle += [f for f, _ in frames]
        every += [f for f, _ in frames]
    for path in args.recordings:
        for f, layer in load(path):
            every.append(f)
            if layer in IDLE_MOTIONS:
                idle.append(f)
    if not idle:
        raise SystemExit("no idle frames")

    joints, rules, report = {}, [], []
    neutral = {}
    for bone in {r[2] for r in RULES}:
        samples = [pose(f[bone]) for f in idle if bone in f]
        p = [median([s[0][i] for s in samples]) for i in range(3)]
        q = [median([s[1][i] for s in samples]) for i in range(4)]
        length = math.sqrt(sum(x * x for x in q))
        neutral[bone] = p + [x / length for x in q]

    found = {}
    for key, name, bone, kind, hint in RULES:
        n = neutral[bone]
        moves = [delta(kind, n, *pose(f[bone])) for f in every if bone in f]
        rests = [delta(kind, n, *pose(f[bone])) for f in idle if bone in f]
        hint_len = math.sqrt(dot(hint, hint))
        hint = [x / hint_len for x in hint]
        # frames beyond the idle range that move mostly along the semantic direction define the axis
        floor = max([dot(d, hint) for d in rests] + [0.0])
        along = [d for d in moves if dot(d, hint) > floor and dot(d, hint) > MIN_COS * math.sqrt(dot(d, d))]
        mean = [sum(d[i] for d in along) / len(along) for i in range(3)] if along else hint
        length = math.sqrt(dot(mean, mean))
        axis = [x / length for x in mean] if length > 1e-9 else hint
        hi = max([dot(d, axis) for d in moves] + [0.0])
        lo = max([dot(d, axis) for d in rests] + [0.0])
        found[name] = (key, bone, kind, n, axis, lo, hi, len(along))

    # the face is symmetric: mirrored rules share the wider range, so a one-sided pose (wink)
    # does not make the other side reach 1.0 early
    def mirror(name):
        return ("R_" + name[2:]) if name.startswith("L_") else ("L_" + name[2:]) if name.startswith("R_") else None
    for key, name, *_ in RULES:
        key, bone, kind, n, axis, lo, hi, count = found[name]
        other = found.get(mirror(name))
        counts = [count]
        if other:
            lo, hi = max(lo, other[5]), max(hi, other[6])
            counts.append(other[7])
        # a mirrored pair is kept or dropped together
        ok = min(counts) >= MIN_FRAMES and hi - lo >= MIN_RANGE[kind] and hi > 2 * lo
        report.append(f"{'ok  ' if ok else 'drop'} {key:20s} {name:22s} lo={lo:6.2f} hi={hi:6.2f} "
                      f"axis=({axis[0]:+.2f},{axis[1]:+.2f},{axis[2]:+.2f}) frames={count}")
        if not ok:
            continue
        joints[name] = {"bone": bone, "kind": kind, "axis": [round(x, 6) for x in axis],
                        "neutral": [round(x, 6) for x in n]}
        rules.append({"key": key, "joint": name, "lo": round(lo, 3), "hi": round(hi, 3),
                      "gain": SHARED.get(key, 1.0)})

    out = {"format": 1, "rig": "MH Rise face_base joints",
           "note": "Generated by tools/rise_calibrate.py from local face_base recordings. Joint pos: millimetres; "
                   "joint rot: degrees. Per-key sum clamped 0..1. The player face never blinks: "
                   "eyeBlink only follows expression eyelids.",
           "joints": joints, "rules": rules}
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if args.signals:
        with open(args.signals[0], encoding="utf-8") as f:
            template = json.load(f)
        keys = {r["key"] for r in rules}
        signals = []
        for entry in template["signals"]:
            raw = entry["raw"] if entry["raw"] in keys else None
            item = {"name": entry["name"], "raw": raw,
                    "note": "face_base 骨骼标定" if raw else "本游戏没有这个信号"}
            if raw and entry.get("guessed"):
                item["guessed"] = True
            signals.append(item)
        with open(args.signals[1], "w", encoding="utf-8", newline="\n") as f:
            json.dump({"schema": template["schema"], "full": 1, "signals": signals}, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"{sum(1 for x in signals if x['raw'])}/{len(signals)} signals available -> {args.signals[1]}")
    print("\n".join(report))
    print(f"{len(rules)} rules, {len(joints)} joints -> {args.out}")


if __name__ == "__main__":
    main()

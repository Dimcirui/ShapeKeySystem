"""check.py <profile.json> <probe tag>...  : verify each driven key moves where its signal expects"""
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
prof = json.load(open(sys.argv[1], encoding="utf-8"))


def signals(node, acc):
    if isinstance(node, dict):
        if "s" in node: acc.append(("s", node["s"]))
        if "eye" in node: acc.append(("eye", (node["axis"], node["sign"])))
        for k in ("sum", "min", "max", "mul"):
            for c in node.get(k, []): signals(c, acc)
    return acc


def expect(sig, v, side):
    n, mx, cx, cy, cz, dx, dy, dz, px, iz, io, oz, oo = v
    errs = []
    if side == "L" and px < 0.8: errs.append(f"side +x={px:.2f}")
    if side == "R" and px > 0.2: errs.append(f"side +x={px:.2f}")
    kind, s = sig
    if kind == "eye":
        axis, sign = s
        val = dz if axis == "pitch" else dx
        if val * sign <= 0: errs.append(f"gaze {axis}{sign:+d} but d{'z' if axis=='pitch' else 'x'}={val*1000:+.2f}")
        return errs
    b = s.split(".")[0]
    rules = {
        "browOuterUp": oz > 0, "browDown": dz < 0, "browInnerUp": iz > 0, "browBring": iz < 0 or io < 0,
        "blink": dz < 0, "eyeSquint": dz < 0 or iz < 0 or oz < 0, "cheekSquint": dz > 0, "puff": oo > 0 or dy < 0,
        "jawOpen": dz < 0, "smile": oz > 0, "frown": oz < 0, "stretch": oo > 0, "funnelTogether": oo < 0,
    }
    if b == "mouthMove":
        d = s.split(".")[1]
        ok = {"left": dx > 0, "right": dx < 0, "up": dz > 0, "down": dz < 0}[d]
        if not ok: errs.append(f"mouthMove.{d} dx={dx*1000:+.2f} dz={dz*1000:+.2f}")
    elif b in rules and not rules[b]:
        errs.append(f"{b}: dz={dz*1000:+.2f} in(z{iz*1000:+.1f} o{io*1000:+.1f}) out(z{oz*1000:+.1f} o{oo*1000:+.1f})")
    return errs


for tag in sys.argv[2:]:
    p = json.load(open(os.path.join(HERE, "probe", tag + ".json"), encoding="utf-8"))
    hit, bad = 0, 0
    for ch in prof["channels"]:
        names = [ch["name"]] + ch.get("any", [])
        key = next((nm for nm in names if nm in p["keys"]), None)
        if key is None:
            continue
        hit += 1
        v = p["keys"][key]
        if len(v) == 1:
            print(f"  {tag:9s} {key:28s} NO MOTION"); bad += 1; continue
        sigs = signals(ch, [])
        if not sigs:
            continue
        side = None
        if ch["group"] != "gaze" and sigs and sigs[0][0] == "s":
            sides = {x[1].rsplit(".", 1)[-1] for x in sigs if x[0] == "s"}
            side = sides.pop() if len(sides) == 1 and sides <= {"L", "R"} else None
        for e in expect(sigs[0], v, side):
            print(f"  {tag:9s} {key:28s} {'(guessed) ' if ch.get('guessed') else ''}{e}"); bad += 1
    print(f"{prof['id']} on {tag}: {hit} keys driven, {bad} flags")

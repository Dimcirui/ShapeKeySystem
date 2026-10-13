"""q.py <tag> <regex> [regex...]  -> per key: moved verts, max disp(mm), +x share, height(0..1 in head), motion dir
dir letters: U/D = +z/-z, L/R = +x/-x (Blender x; +x = character's left if front is -y), F/B = -y/+y
"""
import json, re, sys, os
sys.stdout.reconfigure(encoding="utf-8")
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe")
tag = sys.argv[1]
p = json.load(open(os.path.join(D, tag + ".json"), encoding="utf-8"))
lo, hi = p["bbox"]
pats = [re.compile(a, re.I) for a in sys.argv[2:]] or [re.compile(".")]
def dirs(dx, dy, dz):
    m = max(abs(dx), abs(dy), abs(dz)) or 1
    s = ""
    for v, a, b in ((dz, "U", "D"), (dx, "L", "R"), (-dy, "F", "B")):
        r = v / m
        if abs(r) >= 0.35:
            s += (a if r > 0 else b) + ("" if abs(r) > 0.7 else "~")
    return s or "-"
for k, v in p["keys"].items():
    if not any(x.search(k) for x in pats):
        continue
    if len(v) == 1:
        print(f"{k:34s} (no motion)"); continue
    n, mx, cx, cy, cz, dx, dy, dz, px, iz, io, oz, oo = v
    h = (cz - lo[2]) / ((hi[2] - lo[2]) or 1)
    f = lambda a: f"{a*1000:+5.1f}"
    # inner/outer: verts nearer / farther from the face midline. z = up, o = outward (away from midline)
    print(f"{k:34s} n={n:5d} max={mx*1000:5.1f}mm +x={px:4.2f} cx={cx*1000:6.1f} h={h:4.2f} {dirs(dx,dy,dz):8s}"
          f" in(z{f(iz)} o{f(io)}) out(z{f(oz)} o{f(oo)})")

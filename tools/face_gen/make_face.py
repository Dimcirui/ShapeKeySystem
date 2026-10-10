"""Build one ShapeKeySystem face style from a line-art PNG/WebP (dark lines on transparent).

    python make_face.py <style.json> <source image> <reframework dir>

style.json:
  { "id": "chibi", "name": "Q 版大头", "size": 600,
    "zones": { "<zone>": { "boxes": [[x0,y0,x1,y1], ...],      # whole strokes fully inside a box
                           "polys": [[[x,y], ...], ...],        # ink inside a polygon (strokes joined
                           "min_px": 300 } } }                  #   to hair / outline), blobs >= min_px
  zone = brow | eye | cheek | mouth; coordinates are source-image pixels. Zones listed earlier win
  overlaps, so list eye last.

Writes reframework/images/ShapeKeySystem/faces/<id>/face_*.png and
reframework/data/ShapeKeySystem/faces/<id>.json (name, size, hit ellipses in output pixels).
lines = everything outside the zones (cream); per zone: idle (cream, same as the lines), hover
(brighter, faint white halo), sel (gold + gold halo), glow (neutral halo for live activity)."""
import sys, json, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

STYLE, SRC, REF = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(STYLE, encoding="utf-8"))
SIZE = cfg.get("size", 600)
IMG_DIR = os.path.join(REF, "images", "ShapeKeySystem", "faces", cfg["id"])
DATA_DIR = os.path.join(REF, "data", "ShapeKeySystem", "faces")
os.makedirs(IMG_DIR, exist_ok=True)
os.makedirs(DATA_DIR, exist_ok=True)

src = np.asarray(Image.open(SRC).convert("RGBA"))
A = src[..., 3].astype(np.float32) / 255.0
H, Wd = A.shape
ink = A > 0.4
EIGHT = np.ones((3, 3))
lab, _ = ndimage.label(ink, structure=EIGHT)
objs = ndimage.find_objects(lab)

def poly_mask(pts):
    im = Image.new("L", (Wd, H), 0)
    ImageDraw.Draw(im).polygon([tuple(p) for p in pts], fill=255)
    return np.asarray(im) > 0

def box_mask(b):
    m = np.zeros((H, Wd), bool)
    m[b[1]:b[3], b[0]:b[2]] = True
    return m

zones, region = {}, {}
for key, z in cfg["zones"].items():
    m = np.zeros((H, Wd), bool)
    reg = np.zeros((H, Wd), bool)
    for b in z.get("boxes", []):
        reg |= box_mask(b)
        for i, sl in enumerate(objs, 1):
            if sl[1].start >= b[0] and sl[1].stop <= b[2] and sl[0].start >= b[1] and sl[0].stop <= b[3]:
                m |= lab == i
    for p in z.get("polys", []):
        pm = poly_mask(p)
        reg |= pm
        sub, k = ndimage.label(ink & pm, structure=EIGHT)
        if k:
            sizes = ndimage.sum(np.ones_like(sub), sub, range(1, k + 1))
            for j, s in enumerate(sizes, 1):
                if s >= z.get("min_px", 150):
                    m |= sub == j
    zones[key], region[key] = m, reg

# soft ownership (covers each stroke's antialiased edge), earlier zones win
own, taken_hard = {}, np.zeros((H, Wd), bool)
for key, m in zones.items():
    m = m & ~taken_hard
    zones[key] = m
    d = ndimage.binary_dilation(m, iterations=3) & ~taken_hard
    if cfg["zones"][key].get("polys"):
        d &= region[key]
    own[key] = d
    taken_hard |= d
taken = taken_hard.astype(np.float32)

# crop to content, pad to a square
ys, xs = np.nonzero(A > 0.02)
x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
side = max(x1 - x0, y1 - y0) + 16
ox, oy = (x0 + x1) // 2 - side // 2, (y0 + y1) // 2 - side // 2
scale = SIZE / side

def to_img(alpha, rgb):
    full = np.zeros((side, side), np.float32)
    sx0, sy0 = max(0, ox), max(0, oy)
    sx1, sy1 = min(Wd, ox + side), min(H, oy + side)
    full[sy0 - oy:sy1 - oy, sx0 - ox:sx1 - ox] = alpha[sy0:sy1, sx0:sx1]
    a = Image.fromarray(np.uint8(np.clip(full, 0, 1) * 255)).resize((SIZE, SIZE), Image.LANCZOS)
    im = Image.new("RGBA", (SIZE, SIZE), rgb + (0,))
    im.putalpha(a)
    return im

def halo(stroke, rgb, radius, strength):
    a = stroke.getchannel("A").filter(ImageFilter.GaussianBlur(radius))
    b = np.clip(np.asarray(a).astype(np.float32) / 255.0 * strength, 0, 1)
    im = Image.new("RGBA", (SIZE, SIZE), rgb + (0,))
    im.putalpha(Image.fromarray(np.uint8(b * 255)))
    return im

CREAM = (0xE6, 0xE1, 0xD6)
BRIGHT = (0xFF, 0xFB, 0xF2)
GOLD = (0xF0, 0xBE, 0x5A)
GOLD_HALO = (0xD6, 0xA2, 0x4A)

def save(im, name): im.save(os.path.join(IMG_DIR, name))

save(to_img(A * (1 - taken), CREAM), "face_lines.png")
for key, o in own.items():
    za = A * o
    idle = to_img(za, CREAM)
    save(idle, f"face_{key}_idle.png")
    hov = halo(idle, BRIGHT, 3, 0.9); hov.alpha_composite(to_img(za, BRIGHT))
    save(hov, f"face_{key}_hover.png")
    sel = halo(idle, GOLD_HALO, 5, 1.6); sel.alpha_composite(to_img(za, GOLD))
    save(sel, f"face_{key}_sel.png")
    save(halo(idle, BRIGHT, 7, 1.4), f"face_{key}_glow.png")

# hit ellipses (output pixels): one per blob after merging nearby strokes
def P(x, y): return ((x - ox) * scale, (y - oy) * scale)
hit = {}
for key, m in zones.items():
    sub, _ = ndimage.label(ndimage.binary_dilation(m, iterations=cfg["zones"][key].get("merge", 12)))
    ells = []
    for sl in ndimage.find_objects(sub):
        (ax, ay), (bx, by) = P(sl[1].start, sl[0].start), P(sl[1].stop, sl[0].stop)
        ells.append([round((ax + bx) / 2, 1), round((ay + by) / 2, 1), round((bx - ax) / 2 + 4, 1), round((by - ay) / 2 + 4, 1)])
    hit[key] = sorted(ells)
manifest = {"name": cfg["name"], "size": [SIZE, SIZE], "images": f"ShapeKeySystem/faces/{cfg['id']}/", "zones": hit}
json.dump(manifest, open(os.path.join(DATA_DIR, cfg["id"] + ".json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(json.dumps(manifest, ensure_ascii=False))

import sys
from PIL import Image
ref, fid, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = f"{ref}/images/ShapeKeySystem/faces/{fid}/"
sets = [{}, {"eye": "sel", "mouth": "hover"}, {"brow": "sel", "cheek": "sel", "mouth": "sel"}]
W = 600
bg = Image.new("RGBA", (W * 3, W), (0x1D, 0x25, 0x2E, 255))
for i, s in enumerate(sets):
    c = Image.new("RGBA", (W, W), (0x1D, 0x25, 0x2E, 255)); c.alpha_composite(Image.open(d + "face_lines.png"))
    for z in ["brow", "eye", "cheek", "mouth"]: c.alpha_composite(Image.open(d + f"face_{z}_{s.get(z, 'idle')}.png"))
    bg.paste(c, (W * i, 0))
bg.save(out)

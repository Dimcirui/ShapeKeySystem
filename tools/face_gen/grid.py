import sys
from PIL import Image, ImageDraw
import numpy as np
src, x0, y0, x1, y1, k, out = sys.argv[1], *map(int, sys.argv[2:7]), sys.argv[7]
a = np.asarray(Image.open(src).convert("RGBA"))[..., 3]
o = Image.fromarray(255 - a[y0:y1, x0:x1]).convert("RGB").resize(((x1 - x0) * k, (y1 - y0) * k), Image.NEAREST)
d = ImageDraw.Draw(o)
for x in range(x0 - x0 % 10 + 10, x1, 10):
    d.line([((x - x0) * k, 0), ((x - x0) * k, o.height)], fill=(255, 0, 0) if x % 50 == 0 else (255, 200, 200))
    if x % 50 == 0: d.text(((x - x0) * k + 2, 2), str(x), fill=(255, 0, 0))
for y in range(y0 - y0 % 10 + 10, y1, 10):
    d.line([(0, (y - y0) * k), (o.width, (y - y0) * k)], fill=(0, 0, 255) if y % 50 == 0 else (200, 200, 255))
    if y % 50 == 0: d.text((2, (y - y0) * k + 2), str(y), fill=(0, 0, 255))
o.save(out)

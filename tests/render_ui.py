"""Render recorded d2d commands (mock_sks.lua CMDS) to PNG for offline layout checks."""
import os
from PIL import Image, ImageDraw, ImageFont

IMAGES = os.environ.get("SKS_IMAGES") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reframework", "images")
FONTS = {"Microsoft YaHei UI": r"C:\Windows\Fonts\msyh.ttc", "Consolas": r"C:\Windows\Fonts\consola.ttf"}
_font_cache, _img_cache = {}, {}


def col(c):
    c = int(c) & 0xFFFFFFFF
    return ((c >> 16) & 255, (c >> 8) & 255, c & 255, (c >> 24) & 255)


def font(family, size):
    key = (family, size)
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(FONTS.get(family, FONTS["Microsoft YaHei UI"]), int(size))
    return _font_cache[key]


def image(path):
    if path not in _img_cache:
        p = os.path.join(IMAGES, path)
        _img_cache[path] = Image.open(p).convert("RGBA") if os.path.isfile(p) else None
    return _img_cache[path]


def render(cmds, out, bg=(40, 52, 40, 255)):
    W, H = 1920, 1080
    base = Image.new("RGBA", (W, H), bg)
    for c in cmds:
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        k = c[0]
        if k == "rect":
            _, x, y, w, h, cc = c
            d.rectangle([x, y, x + w - 1, y + h - 1], fill=col(cc))
        elif k == "rrect":
            _, x, y, w, h, r, cc = c
            d.rounded_rectangle([x, y, x + w - 1, y + h - 1], radius=r, fill=col(cc))
        elif k == "orect":
            _, x, y, w, h, r, t, cc = c
            d.rounded_rectangle([x, y, x + w - 1, y + h - 1], radius=r, outline=col(cc), width=max(1, int(t)))
        elif k == "line":
            _, x1, y1, x2, y2, t, cc = c
            d.line([x1, y1, x2, y2], fill=col(cc), width=max(1, int(t)))
        elif k == "fcircle":
            _, x, y, r, cc = c
            d.ellipse([x - r, y - r, x + r, y + r], fill=col(cc))
        elif k == "circle":
            _, x, y, r, t, cc = c
            d.ellipse([x - r, y - r, x + r, y + r], outline=col(cc), width=max(1, int(t)))
        elif k == "quad":
            _, x1, y1, x2, y2, x3, y3, x4, y4, cc = c
            d.polygon([(x1, y1), (x2, y2), (x3, y3), (x4, y4)], fill=col(cc))
        elif k == "text":
            _, s, x, y, cc, size, fam = c
            d.text((x, y), s, font=font(fam, size), fill=col(cc))
        elif k == "image":
            _, path, x, y, w, h, a = c
            im = image(path)
            if im is not None:
                im = im.resize((max(1, int(w)), max(1, int(h))))
                if a < 1:
                    im.putalpha(im.getchannel("A").point(lambda v: int(v * a)))
                layer.alpha_composite(im, (int(x), int(y)))
        base.alpha_composite(layer)
    bbox = base.getbbox()
    base.convert("RGB").save(out)

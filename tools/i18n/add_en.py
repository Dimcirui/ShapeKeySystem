"""Add (or refresh) the English fields of the builtin data, in place and without reformatting:
  builtin/profiles/*.json   name_en, description_en (data_en.PROFILE_EN), note_en per channel note
  builtin/signals.json      note_en for notes with Chinese in them
python -I add_en.py [reframework dir]   (default: the repo's reframework/)
Run it after changing a Chinese note; it stops with the sentence that has no English yet
(add it to data_en.py). Only *_en fields are written: the Chinese text and the layout stay as they are.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from data_en import PROFILE_EN, note_en, signal_note_en  # noqa: E402

CJK = re.compile(r"[　-ヿ㐀-鿿＀-￯]")
STR = r'"((?:[^"\\]|\\.)*)"'


def jstr(s):
    return json.dumps(s, ensure_ascii=False)


def strip_en(v):
    if isinstance(v, dict):
        return {k: strip_en(x) for k, x in v.items() if not k.endswith("_en")}
    if isinstance(v, list):
        return [strip_en(x) for x in v]
    return v


def add_notes(text, translate):
    """"note": "zh" [, "note_en": "old"]  ->  "note": "zh", "note_en": "en" (only where zh has CJK)"""
    rx = re.compile(r'"note":(\s*)' + STR + r'(\s*,\s*"note_en":\s*' + STR + r')?')

    def sub(m):
        zh = json.loads('"' + m.group(2) + '"')
        if not CJK.search(zh):
            return m.group(0)
        return f'"note":{m.group(1)}"{m.group(2)}", "note_en": {jstr(translate(zh))}'
    return rx.sub(sub, text)


def add_header(text, key, value, nl):
    """top-level "key": "..." line (2-space indent) -> followed by "key_en": value"""
    rx = re.compile(r'^(  "' + key + r'":\s*' + STR + r',)' + re.escape(nl) + r'(  "' + key + r'_en":\s*' + STR + r',' + re.escape(nl) + r')?',
                    re.M)
    m = rx.search(text)
    if not m:
        raise SystemExit(f"no top-level {key!r} line")
    return text[:m.start()] + m.group(1) + nl + f'  "{key}_en": {jstr(value)},' + nl + text[m.end():]


def process(path, fn):
    raw = open(path, encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"
    out = fn(raw, nl)
    before, after = json.loads(raw), json.loads(out)
    if strip_en(before) != strip_en(after):
        raise SystemExit(f"{path}: content other than *_en changed")
    if out != raw:
        open(path, "w", encoding="utf-8", newline="").write(out)
        print("updated", path)
    return after


def main():
    rf = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "reframework")
    base = os.path.join(rf, "data", "ShapeKeySystem", "builtin")
    pdir = os.path.join(base, "profiles")
    for fn in sorted(os.listdir(pdir)):
        if not fn.endswith(".json"):
            continue
        path = os.path.join(pdir, fn)
        pid = json.load(open(path, encoding="utf-8")).get("id") or fn[:-5]
        if pid not in PROFILE_EN:
            raise SystemExit(f"{fn}: add {pid!r} to data_en.PROFILE_EN")
        name_en, desc_en = PROFILE_EN[pid]

        def fix(raw, nl):
            t = add_header(raw, "name", name_en, nl)
            if '"description"' in t:
                t = add_header(t, "description", desc_en, nl)
            return add_notes(t, note_en)
        d = process(path, fix)
        for ch in d.get("channels", []):
            if ch.get("note") and CJK.search(ch["note"]) and not ch.get("note_en"):
                raise SystemExit(f"{fn}: {ch['name']} note left without note_en")
    process(os.path.join(base, "signals.json"), lambda raw, nl: add_notes(raw, signal_note_en))


if __name__ == "__main__":
    main()

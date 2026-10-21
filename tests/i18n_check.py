"""English interface coverage: every Chinese literal in the scripts and every translatable text of
the builtin data has an entry in builtin/i18n/en*.json, with the same format specifiers.

Run by run.py (prints "I18N FAILS: n"); `python -I tests/i18n_check.py` runs it alone.
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("SKS_REFRAMEWORK") or os.path.join(HERE, "..", "reframework")
CJK = re.compile(r"[　-ヿ一-鿿＀-￯]")
SPEC = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?[sdifgxXqc%]")
BS = chr(92)
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", BS: BS}


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == BS and i + 1 < len(s):
            out.append(ESCAPES.get(s[i + 1], s[i + 1])); i += 2
        else:
            out.append(s[i]); i += 1
    return "".join(out)


def lua_strings(src):
    """Short-string literals outside comments: (line, text)."""
    i, n, line, out = 0, len(src), 1, []
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i)
                line += src.count("\n", i, j); i = j + len(close); continue
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if c in "\"'":
            q, j = c, i + 1
            while j < n and src[j] != q:
                j += 2 if src[j] == BS else 1
            out.append((line, unescape(src[i + 1:j]))); i = j + 1; continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            line += src.count("\n", i, j); i = j + len(close); continue
        i += 1
    return out


def data_texts(root):
    """Translatable Chinese texts of the builtin data: (file, text)."""
    base = os.path.join(root, "data", "ShapeKeySystem")
    out = []

    def add(f, v):
        if isinstance(v, str) and CJK.search(v):
            out.append((os.path.relpath(f, base), v))

    for f in glob.glob(os.path.join(base, "builtin", "profiles", "*.json")) + \
            glob.glob(os.path.join(base, "builtin", "*", "profiles", "*.json")):
        d = json.load(open(f, encoding="utf-8"))
        add(f, d.get("name")); add(f, d.get("description"))
        for c in d.get("channels") or []:
            add(f, c.get("note"))
    for f in glob.glob(os.path.join(base, "builtin", "*", "signals.json")):
        for e in json.load(open(f, encoding="utf-8")).get("signals") or []:
            add(f, e.get("note"))
    for f in glob.glob(os.path.join(base, "faces", "*.json")):
        add(f, json.load(open(f, encoding="utf-8")).get("name"))
    for f in glob.glob(os.path.join(base, "builtin", "*", "recordings", "*.json")):
        add(f, json.load(open(f, encoding="utf-8")).get("label"))
    return out


def main():
    fails = 0

    def check(ok, what):
        nonlocal fails
        print(("ok   " if ok else "FAIL ") + "[i18n] " + what)
        if not ok:
            fails += 1

    idir = os.path.join(ROOT, "data", "ShapeKeySystem", "builtin", "i18n")
    strings, untranslated = {}, set()
    for name in ("en.json", "en_data.json"):
        path = os.path.join(idir, name)
        check(os.path.isfile(path), name + " exists")
        if os.path.isfile(path):
            d = json.load(open(path, encoding="utf-8"))
            strings.update(d.get("strings") or {})
            untranslated.update(d.get("untranslated") or [])

    missing = []
    for f in sorted(glob.glob(os.path.join(ROOT, "autorun", "**", "*.lua"), recursive=True)):
        rel = os.path.relpath(f, os.path.join(ROOT, "autorun"))
        for line, s in lua_strings(open(f, encoding="utf-8").read()):
            if CJK.search(s) and s not in strings and s not in untranslated:
                missing.append("%s:%d %s" % (rel, line, s))
    check(not missing, "every Chinese literal in the scripts has an entry (%d missing)%s"
          % (len(missing), "".join("\n       " + m for m in missing[:25])))

    dmiss = sorted({"%s %s" % (f, s[:60]) for f, s in data_texts(ROOT) if s not in strings})
    check(not dmiss, "every builtin data text has an entry (%d missing)%s"
          % (len(dmiss), "".join("\n       " + m for m in dmiss[:25])))

    bad = [k for k, v in strings.items()
           if not isinstance(v, str) or not v.strip() or SPEC.findall(k) != SPEC.findall(v)]
    check(not bad, "translations are non-empty and keep the format specifiers in order%s"
          % "".join("\n       " + k for k in bad[:25]))
    check("中文" not in strings, "the language picker's own name for Chinese is not translated")
    print("I18N FAILS:\t%d" % fails)
    return fails


if __name__ == "__main__":
    sys.exit(1 if main() else 0)

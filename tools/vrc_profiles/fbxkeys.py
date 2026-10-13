"""List mesh models and their blendshape channel names from binary FBX files.
usage: python -I fbxkeys.py <root> <out.json>
"""
import json, os, struct, sys


def read_nodes(f, end, v64, depth, want):
    out = []
    hdr = 25 if v64 else 13
    while f.tell() < end:
        if v64:
            eo, np_, pl = struct.unpack("<QQQ", f.read(24))
        else:
            eo, np_, pl = struct.unpack("<III", f.read(12))
        nl = f.read(1)[0]
        if eo == 0:
            break
        name = f.read(nl).decode("latin1")
        pstart = f.tell()
        props = []
        keep = want(depth, name)
        if keep:
            for _ in range(np_):
                t = f.read(1)
                if t in b"SR":
                    n = struct.unpack("<I", f.read(4))[0]
                    d = f.read(n)
                    props.append(d.decode("utf-8", "replace") if t == b"S" else None)
                elif t == b"L":
                    props.append(struct.unpack("<q", f.read(8))[0])
                elif t == b"I":
                    props.append(struct.unpack("<i", f.read(4))[0])
                elif t == b"D":
                    props.append(struct.unpack("<d", f.read(8))[0])
                elif t == b"F":
                    props.append(struct.unpack("<f", f.read(4))[0])
                elif t == b"Y":
                    props.append(struct.unpack("<h", f.read(2))[0])
                elif t in b"CB":
                    props.append(f.read(1)[0])
                elif t in b"fdlibc":
                    _, _, clen = struct.unpack("<III", f.read(12))
                    f.seek(clen, 1)
                    props.append(None)
                else:
                    break
        f.seek(pstart + pl)
        children = []
        if f.tell() < eo:
            if keep:
                children = read_nodes(f, eo - hdr, v64, depth + 1, want)
            f.seek(eo)
        out.append((name, props, children))
    return out


def want(depth, name):
    if depth == 0:
        return name in ("Objects", "Connections")
    if depth == 1:
        return name in ("Model", "Geometry", "Deformer", "C")
    return False


def clean(s):
    # "name\x00\x01Class" -> name ; "Class::name" -> name
    if "\x00\x01" in s:
        return s.split("\x00\x01")[0]
    return s.split("::", 1)[1] if "::" in s else s


def scan(path):
    with open(path, "rb") as f:
        head = f.read(27)
        if not head.startswith(b"Kaydara FBX Binary"):
            return {"error": "not binary fbx"}
        ver = struct.unpack("<I", head[23:27])[0]
        f.seek(0, 2)
        size = f.tell()
        f.seek(27)
        top = read_nodes(f, size, ver >= 7500, 0, want)
    objs = {}
    parent = {}
    for name, props, ch in top:
        if name == "Objects":
            for n, p, _ in ch:
                if len(p) >= 3 and isinstance(p[0], int):
                    objs[p[0]] = (n, clean(p[1] or ""), p[2])
        elif name == "Connections":
            for n, p, _ in ch:
                if len(p) >= 3 and p[0] == "OO":
                    parent.setdefault(p[1], []).append(p[2])
    # child -> parents; build mesh model -> channel names
    def parents(i):
        return parent.get(i, [])
    meshes = {}
    for oid, (kind, nm, cls) in objs.items():
        if kind == "Deformer" and cls == "BlendShapeChannel":
            for bs in parents(oid):            # channel -> BlendShape
                for geo in parents(bs):        # BlendShape -> Geometry
                    for mdl in parents(geo):   # Geometry -> Model
                        if mdl in objs and objs[mdl][0] == "Model":
                            meshes.setdefault(objs[mdl][1], []).append(nm)
    models = [nm for (k, nm, cls) in objs.values() if k == "Model" and cls == "Mesh"]
    return {"meshes": models, "keys": meshes}


def main():
    root, out = sys.argv[1], sys.argv[2]
    res = {}
    for dp, _, fs in os.walk(root):
        for fn in fs:
            if fn.lower().endswith(".fbx"):
                p = os.path.join(dp, fn)
                try:
                    res[os.path.relpath(p, root)] = scan(p)
                except Exception as e:
                    res[os.path.relpath(p, root)] = {"error": repr(e)}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()

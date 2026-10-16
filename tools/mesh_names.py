"""Write a names table (sks.names/1) from the strings in RE Engine .mesh files.

For engines where SKS reads channel names back from their hashes (Onimusha, Rise): every string
in the mesh becomes a candidate name. Strings that are not channel names (bones, materials) never
match a channel hash and are ignored by SKS.

    python -I tools/mesh_names.py OUT.json MESH [MESH ...]

Put OUT.json in reframework/data/ShapeKeySystem/mods/names/ (shipped with the mod) or user/names/.
"""
import json
import sys


def strings(data):
    seen, out = set(), []
    for chunk in data.split(b"\0"):
        try:
            s = chunk.decode("utf-8")
        except UnicodeDecodeError:
            continue
        # a channel name may hold spaces, brackets or non-ASCII; drop only empty and control text
        if len(s) < 2 or not s.isprintable() or s in seen:
            continue
        seen.add(s)
        out.append(s)
    return out


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    names = []
    for path in argv[2:]:
        with open(path, "rb") as f:
            for s in strings(f.read()):
                if s not in names:
                    names.append(s)
    with open(argv[1], "w", encoding="utf-8", newline="\n") as f:
        json.dump({"schema": "sks.names/1", "names": names}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{len(names)} names -> {argv[1]}")


if __name__ == "__main__":
    main(sys.argv)

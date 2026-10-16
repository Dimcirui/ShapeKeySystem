"""Convert a legacy model profile into SKS mod data without changing its input."""
import argparse
import copy
import json
import re
from pathlib import Path


def sculpt_key(name):
    return re.sub(r"_[Ll][Oo][Dd]\d+$", "", name.rsplit(".", 1)[-1])


def convert(source, arkit, profile_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", profile_id):
        raise ValueError("profile id must be an ASCII basename")
    if not isinstance(source.get("keys"), list) or not source["keys"]:
        raise ValueError("keys must be a non-empty array")
    native_map = source.get("native_map_file", "RE4R_ShapeKeySystem_native_leon.json")
    if native_map not in {"RE4R_ShapeKeySystem_native_leon.json", "RE4R_ShapeKeySystem_native_leon_mouth9.json"}:
        raise ValueError("custom native maps need an explicit adapter port")
    canonical = {c["name"]: c for c in arkit["channels"]}
    channels, names, skipped, manual, sculpt, seen = [], [], [], [], [], set()
    labels = {}
    sculpt_regions = {"shape", "body", "outfit", "hair", "eye_detail", "mouth_detail", "outfit_variant", "hairstyle"}
    groups = {"brow", "eye", "gaze", "nose_cheek", "mouth", "jaw", "tongue", "extra"}
    native = {t["name"] for t in source.get("native_taps", [])}
    node_keys = {"s", "p", "ref", "const", "eye", "axis", "sign", "sum", "max", "min", "mul", "sub", "k", "curve", "full_deg"}
    for key in source["keys"]:
        if not isinstance(key, dict) or any(not isinstance(key.get(f), str) for f in ("id", "name", "label", "library", "group", "region")):
            raise ValueError("each key needs string id/name/label/library/group/region")
        name = key["id"]
        if not name or name in seen:
            raise ValueError("channel ids must be non-empty and unique")
        seen.add(name)
        if name.startswith("Face__geo__") or name.startswith("crct_") or name in native:
            skipped.append(name)
            continue
        if name.startswith("#"):
            raise ValueError("unresolved hash labels cannot be converted into writable keys")
        if type(key.get("hash")) is not int or not 0 <= key["hash"] <= 0xFFFFFFFF:
            raise ValueError("hash must be an unsigned 32-bit integer")
        names.append(name)
        labels[name] = key["label"]
        labels[sculpt_key(name)] = key["label"]
        # Profile membership transfers channel ownership to the expression writer, even without a node.
        if key["region"] in sculpt_regions:
            sculpt.append(name)
            continue
        mappings = [[key["name"], 1]] if key["library"] == "ARKit" else key.get("arkit", [])
        nodes = []
        for mapping in mappings:
            if not isinstance(mapping, list) or len(mapping) != 2 or mapping[0] not in canonical:
                raise ValueError("unknown or malformed ARKit mapping")
            gain = mapping[1]
            if type(gain) not in (int, float) or not float("-inf") < gain < float("inf"):
                raise ValueError("mapping gain must be finite")
            node = {k: copy.deepcopy(v) for k, v in canonical[mapping[0]].items() if k in node_keys}
            if not node:
                continue
            if gain != 1:
                node = {"mul": [node, {"const": gain}]}
            nodes.append(node)
        group = key["group"] if key["group"] in groups else {"nose": "nose_cheek"}.get(key["region"], key["region"])
        entry = {"name": name, "group": group if group in groups else "extra", "note": key["label"]}
        if nodes:
            entry.update(nodes[0] if len(nodes) == 1 else {"sum": nodes})
        else:
            manual.append(name)
        channels.append(entry)
    if not names:
        raise ValueError("profile has no writable channels")
    return {
        "profiles/" + profile_id + ".json": {"schema": "sks.profile/1", "name": source.get("title", profile_id), "channels": channels},
        "names/" + profile_id + ".json": {"schema": "sks.names/1", "names": names, "labels": labels},
        "leon/sculpt/" + profile_id + ".json": {"schema": "sks.sculpt/1", "name": profile_id,
            "values": {sculpt_key(name): 0 for name in names}},
        "leon/leon.json": {"schema": "sks.binding/1", "part": "leon", "profile": profile_id,
            "sculpt": profile_id, "global": True},
        "conversion-report.json": {"source_native_map": native_map, "skipped_read_only": skipped, "manual_only": manual,
            "sculpt_only": sculpt,
            "notes": ["Original settings and presets are not migrated.",
                      "SKS remaps expressions above sculpt rest values; it does not reproduce legacy additive mixing.",
                      "Identical names on several parts follow SKS merging; inspect coverage before driving.",
                      "Leon calibration only; game verification is still required."]},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--id", required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory containing mod data")
    args = parser.parse_args()
    arkit = Path(__file__).resolve().parents[1] / "reframework/data/ShapeKeySystem/builtin/profiles/arkit.json"
    files = convert(json.loads(args.input.read_text(encoding="utf-8-sig")), json.loads(arkit.read_text(encoding="utf-8")), args.id)
    # The entire conversion is validated before creating any directory; existing outputs are never overwritten.
    if args.output.exists():
        parser.error("output already exists; choose a new directory")
    for path, data in files.items():
        target = args.output / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Converted", len(files), "files to", args.output)


if __name__ == "__main__":
    main()

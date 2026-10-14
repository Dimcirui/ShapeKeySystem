"""Generate the Onimusha signal dictionary from a local original JCNS using RE-JCNS-Editor."""
import argparse
import contextlib
import io
import json
import sys
from pathlib import Path

# Only single FACS shapes are used; combined correctives are not independent signals.
TARGETS = {
    "blink": "eyeClosed", "eyeWide": "eyeOpen", "eyeSquint": "lidTightener",
    "browBring": "browLowerer", "browDown": "browLowerer", "browInnerUp": "innerBrowRaiser",
    "browOuterUp": "outerBrowRaiser", "sneer": "noseWrinkler", "upperLipUp": "upperLipRaiser",
    "smile": "lipCornerPuller", "dimple": "dimpler", "stretch": "lipStretcher",
    "frown": "lipCornerDepressor", "lowerLipDown": "lowerLipDepressor",
    "puff": "cheekPuff", "cheekSquint": "cheekRaiser",
    "funnel": "upperLipFunneler", "press": "lipPressor", "funnelTogether": "lipPucker",
    "lipsTogether": "lipPressor", "chinRaise": "chinRaiser", "jawOpen": "jawOpen",
    "mouthMove.left": "mouthLeft", "mouthMove.right": "mouthRight",
    "cheekShrink": "cheekSuck_R", "upperLipRoll": "upperLipSuck", "lowerLipRoll": "lowerLipSuck",
}
SHARED = {"funnel", "press", "funnelTogether", "lipsTogether"}
GUESSED = {"browBring", "funnel", "funnelTogether", "lipsTogether", "cheekShrink"}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--modules", type=Path, required=True, help="RE-JCNS-Editor/modules")
    cli.add_argument("--jcns", type=Path, required=True)
    cli.add_argument("--full", type=float, required=True, help="Full value in runtime local-position units")
    cli.add_argument("--output", type=Path, required=True)
    args = cli.parse_args()
    if not 0 < args.full < float("inf"):
        cli.error("--full must be positive and finite")
    sys.path.insert(0, str(args.modules.resolve()))
    from jcns_parser import JCNSParser
    parser = JCNSParser(str(args.jcns.resolve()))
    with contextlib.redirect_stdout(io.StringIO()):
        constraints = parser.parse()
    if parser.version != 36:
        raise ValueError("Expected Onimusha JCNS v36")
    mappings = {}
    for constraint in constraints:
        target = constraint["ObjectName"]
        if not target.startswith("blendShape") or "." not in target:
            continue
        sources = constraint["sources"]
        if len(sources) != 1:
            continue
        source = sources[0]
        if not source["SourceName"].startswith("bsControl_") or source["InputType"] != 0:
            continue
        if (source["from_start"], source["from_end"], source["to_start"], source["to_end"]) != (0, 1, 0, 1):
            continue
        axis = source["source_axis"]
        if axis not in (0, 1, 2):
            continue
        name = target.split(".", 1)[1]
        raw = source["SourceName"] + "." + "xyz"[axis]
        if name in mappings and mappings[name] != raw:
            raise ValueError("Conflicting FACS mapping: " + name)
        mappings[name] = raw
    root = Path(__file__).resolve().parents[1]
    wilds = json.loads((root / "reframework/data/ShapeKeySystem/builtin/mhwilds/signals.json").read_text(encoding="utf-8"))
    signals = []
    for entry in wilds["signals"]:
        name = entry["name"]
        base, _, side = name.rpartition(".")
        if side not in ("L", "R"):
            base, side = name, ""
        target = TARGETS.get(base)
        if target and side and base not in SHARED:
            target += "_" + side
        raw = mappings.get(target)
        if target and not raw:
            raise ValueError("Missing FACS mapping: " + target)
        output = {"name": name, "raw": raw}
        if raw:
            output["note"] = target + ("（左右共用）" if base in SHARED else "")
            if base in GUESSED:
                output["guessed"] = True
        signals.append(output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"schema": "sks.signals/2", "full": args.full, "signals": signals}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Signals: {len(signals)}, mapped: {sum(s['raw'] is not None for s in signals)}, full: {args.full}")


if __name__ == "__main__":
    main()

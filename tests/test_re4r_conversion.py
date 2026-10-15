"""Synthetic conversion contracts; no model or game data is required."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("convert_re4r", ROOT / "tools/convert_re4r_profile.py")
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)
ARKIT = json.loads((ROOT / "reframework/data/ShapeKeySystem/builtin/profiles/arkit.json").read_text(encoding="utf-8"))


def key(name, **extra):
    return dict(id="SK__demo." + name, name=name, label="Synthetic " + name,
                library="ARKit", group="eye", region="eye", hash=123, **extra)


class ConversionTest(unittest.TestCase):
    def test_exact_name_and_source_unchanged(self):
        source = {"keys": [key("eyeBlinkLeft")]}
        saved = copy.deepcopy(source)
        out = converter.convert(source, ARKIT, "demo")
        channel = out["profiles/demo.json"]["channels"][0]
        self.assertEqual(channel["name"], "SK__demo.eyeBlinkLeft")
        self.assertEqual(channel["s"], "blink.L")
        self.assertEqual(source, saved)
        self.assertEqual(out["names/demo.json"]["names"], [channel["name"]])

    def test_weighted_mmd_mapping_and_manual(self):
        mapped = key("smile")
        mapped.update(library="MMD", arkit=[["mouthSmileLeft", 0.5], ["mouthSmileRight", 0.25]])
        manual = key("size"); manual.update(library="custom")
        out = converter.convert({"keys": [mapped, manual]}, ARKIT, "demo")
        channels = out["profiles/demo.json"]["channels"]
        self.assertEqual(channels[0]["sum"][0]["mul"][1], {"const": 0.5})
        self.assertNotIn("s", channels[1])
        self.assertEqual(out["conversion-report.json"]["manual_only"], [manual["id"]])

    def test_native_input_excluded(self):
        native = key("jawOpen"); native["id"] = "Face__geo__p000_cbs.crct_jaw_openExtreme"
        out = converter.convert({"keys": [native, key("eyeBlinkLeft")]}, ARKIT, "demo")
        self.assertEqual(len(out["profiles/demo.json"]["channels"]), 1)
        self.assertEqual(out["conversion-report.json"]["skipped_read_only"], [native["id"]])

    def test_invalid_inputs_rejected(self):
        invalid = [
            {"keys": []}, {"keys": [key("eyeBlinkLeft"), key("eyeBlinkLeft")]},
            {"keys": [key("eyeBlinkLeft")], "native_map_file": "../unsafe.json"},
            {"keys": [{**key("eyeBlinkLeft"), "hash": -1}]},
            {"keys": [{**key("bad"), "arkit": [["notARKit", 1]], "library": "MMD"}]},
            {"keys": [{**key("bad"), "arkit": [["jawOpen", float("nan")]], "library": "MMD"}]},
        ]
        for source in invalid:
            with self.subTest(source=source), self.assertRaises(ValueError):
                converter.convert(source, ARKIT, "demo")
        with self.assertRaises(ValueError):
            converter.convert({"keys": [key("eyeBlinkLeft")]}, ARKIT, "../x")

    def test_cli_output_is_new_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); source = root / "input.json"; output = root / "converted"
            source.write_text(json.dumps({"keys": [key("eyeBlinkLeft")]}), encoding="utf-8")
            before = source.read_bytes()
            command = [sys.executable, str(ROOT / "tools/convert_re4r_profile.py"), str(source), "--id", "demo", "--output", str(output)]
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(len(list(output.rglob("*.json"))), 4)
            self.assertEqual(source.read_bytes(), before)
            result = subprocess.run(command, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

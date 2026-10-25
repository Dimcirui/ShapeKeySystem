"""RhyLive 桥接的 OSC 解析：普通消息、bundle、错误类型标签、非有限值。"""
import importlib.util
import math
from pathlib import Path
import struct
import unittest

BRIDGE = Path(__file__).resolve().parents[1] / "reframework" / "data" / "ShapeKeySystem" / "builtin" / "mocap" / "rhylive_bridge.py"
spec = importlib.util.spec_from_file_location("rhylive_bridge", BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def osc_str(s):
    b = s.encode("ascii") + b"\0"
    return b + b"\0" * (-len(b) % 4)


def message(address, values, tags=None):
    tags = tags if tags is not None else "," + "f" * len(values)
    return osc_str(address) + osc_str(tags) + struct.pack(">%df" % len(values), *values)


def bundle(*elements):
    out = osc_str("#bundle") + b"\0" * 8
    for e in elements:
        out += struct.pack(">i", len(e)) + e
    return out


def face(v0=0.5):
    vals = [0.0] * 52
    vals[0], vals[24], vals[51] = v0, 1.7, -0.2   # browDownLeft, jawOpen (clamped), tongueOut (clamped)
    return vals


class OscParseTest(unittest.TestCase):

    def test_plain_message(self):
        frames = bridge.parse(message("/Face", face()))
        self.assertEqual(len(frames), 1)
        self.assertAlmostEqual(frames[0][0], 0.5)
        self.assertEqual(frames[0][24], 1.0)
        self.assertEqual(frames[0][51], 0.0)

    def test_bundle_nested_and_other_addresses(self):
        pkt = bundle(message("/Other", [1.0]), bundle(message("/Face", face(0.25))), message("/Face", face(0.75)))
        frames = bridge.parse(pkt)
        self.assertEqual([round(f[0], 4) for f in frames], [0.25, 0.75])

    def test_wrong_tag_count(self):
        self.assertEqual(bridge.parse(message("/Face", face()[:51])), [])
        self.assertEqual(bridge.parse(message("/Face", face()[:51] + [1], tags="," + "f" * 51 + "i")), [])

    def test_non_finite_dropped(self):
        vals = face()
        vals[3] = math.nan
        self.assertEqual(bridge.parse(message("/Face", vals)), [])
        vals[3] = math.inf
        self.assertEqual(bridge.parse(message("/Face", vals)), [])

    def test_malformed_packets(self):
        good = message("/Face", face())
        self.assertEqual(bridge.parse(good[:-4]), [])
        self.assertEqual(bridge.parse(good + b"\0"), [])
        self.assertEqual(bridge.parse(b"/Face"), [])
        broken = bundle(good)
        broken = broken[:16] + struct.pack(">i", len(good) + 4) + broken[20:]
        self.assertEqual(bridge.parse(broken), [])
        deep = good
        for _ in range(20):
            deep = bundle(deep)
        self.assertEqual(bridge.parse(deep), [])


if __name__ == "__main__":
    unittest.main()

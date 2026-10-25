"""tools/strip-lua.ps1：发布包去掉 Lua 注释时，代码和字符串不变、行号不变。"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import lupa.lua54 as lupa

REPO = Path(__file__).resolve().parents[1]
STRIP = REPO / "tools" / "strip-lua.ps1"

SAMPLE = """local a = "-- not a comment" -- comment
local b = '\\'--' --[[ block
comment ]] local c = 1
local d = [==[ -- kept ]] still ]==] --[==[ x ]] y ]==]
local e = "a\\z
   -- kept"
-- whole line
return a, b, c, d, e
"""

EXPECTED = """local a = "-- not a comment"
local b = '\\'--'
 local c = 1
local d = [==[ -- kept ]] still ]==]
local e = "a\\z
   -- kept"

return a, b, c, d, e
"""


class StripLuaTest(unittest.TestCase):
    def setUp(self):
        self.shell = shutil.which("pwsh") or shutil.which("powershell")
        if not self.shell:
            self.skipTest("PowerShell is required")
        self.temporary = tempfile.TemporaryDirectory(prefix="sks_strip_test_")
        self.root = Path(self.temporary.name)
        self.lua = lupa.LuaRuntime()

    def tearDown(self):
        self.temporary.cleanup()

    def strip(self, source, dest):
        result = subprocess.run([self.shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(STRIP),
                                 "-Source", str(source), "-Dest", str(dest)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def run_lua(self, text):
        return tuple(self.lua.execute(text))

    def test_lexing(self):
        src = self.root / "src"
        src.mkdir()
        (src / "sample.lua").write_bytes(SAMPLE.encode("utf-8"))
        (src / "crlf.lua").write_bytes(SAMPLE.replace("\n", "\r\n").encode("utf-8"))
        (src / "bom.lua").write_bytes(b"\xef\xbb\xbf" + SAMPLE.encode("utf-8"))
        self.strip(src, self.root / "out")
        out = (self.root / "out" / "sample.lua").read_bytes().decode("utf-8")
        self.assertEqual(out, EXPECTED)
        self.assertEqual(self.run_lua(out), self.run_lua(SAMPLE))
        self.assertEqual((self.root / "out" / "crlf.lua").read_bytes(), EXPECTED.replace("\n", "\r\n").encode("utf-8"))
        self.assertEqual((self.root / "out" / "bom.lua").read_bytes(), b"\xef\xbb\xbf" + EXPECTED.encode("utf-8"))

    def test_repo_sources(self):
        src = REPO / "reframework" / "autorun"
        self.strip(src, self.root / "autorun")
        load = self.lua.eval("function(s, n) local f, e = load(s, n); return e end")
        files = sorted(src.rglob("*.lua"))
        self.assertGreater(len(files), 0)
        for f in files:
            before = f.read_bytes().decode("utf-8-sig")
            after = (self.root / "autorun" / f.relative_to(src)).read_bytes().decode("utf-8-sig")
            self.assertEqual(after.count("\n"), before.count("\n"), f.name)
            self.assertIsNone(load(after, f.name), f.name)
            self.assertFalse([l for l in after.split("\n") if l.lstrip().startswith("--")], f.name)


if __name__ == "__main__":
    unittest.main()

"""在临时目录验证发布 zip 的结构，REF-IME 用本地伪造的 Release zip 代替，不联网。"""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[1]


class PackageTest(unittest.TestCase):
    """仓库副本里混入玩家数据，打包结果只能包含发布清单内的文件。"""

    def setUp(self):
        self.shell = shutil.which("pwsh") or shutil.which("powershell")
        if not self.shell:
            self.skipTest("PowerShell is required for packaging tests")
        self.temporary = tempfile.TemporaryDirectory(prefix="sks_package_test_")
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "repo"
        for name in ("package.ps1", "sks-files.ps1", "strip-lua.ps1"):
            target = self.source / "tools" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / "tools" / name, target)
        self.put("reframework/autorun/ShapeKeySystem.lua", b"-- entry")
        self.put("reframework/autorun/ShapeKeySystem_Core/Version.lua",
                 b'local V = {}\nV.number = "9.8.7"\nreturn V\n')
        self.put("reframework/autorun/ShapeKeySystem_Core/__pycache__/x.pyc", b"cache")
        self.put("reframework/autorun/ShapeKeySystem_UI/Panel.lua", b"-- ui")
        self.put("reframework/autorun/ShapeKeySystem_Games/Registry.lua", b"-- games")
        self.put("reframework/data/ShapeKeySystem/builtin/arkit.json", b"{}")
        self.put("reframework/data/ShapeKeySystem/faces/default.json", b"{}")
        self.put("reframework/images/ShapeKeySystem/faces/a.png", b"png")
        self.put("natives/STM/GUI/ui_texture/tex_render/rtt_facemirror_00.rtex.6", b"RTEX")
        self.put("natives/STM/other_mod.tex", b"not ours")
        for player in ("settings.json", "user/presets/p.json", "mods/m.json", "trail.log"):
            self.put("reframework/data/ShapeKeySystem/" + player, b"player data")
        self.put("reframework/autorun/other_mod.lua", b"-- not ours")
        self.screenshot = self.put("shot.jpg", b"\xff\xd8\xff\xe0 jpeg")
        self.ime_zip = self.root / "REF-IME-v1.2.3-windows-x64.zip"
        with zipfile.ZipFile(self.ime_zip, "w") as archive:
            archive.writestr("reframework/plugins/REF-IME.dll", b"dll bytes")
        self.ime_sha = hashlib.sha256(self.ime_zip.read_bytes()).hexdigest()

    def tearDown(self):
        self.temporary.cleanup()

    def put(self, relative, content):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def run_package(self, *arguments, screenshot=True):
        shot = ["-Screenshot", str(self.screenshot)] if screenshot else []
        return subprocess.run(
            [self.shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.source / "tools" / "package.ps1"), *shot,
             "-RefImeZip", str(self.ime_zip), "-RefImeVersion", "v1.2.3", *arguments],
            capture_output=True)

    def test_zip_layout(self):
        result = self.run_package("-RefImeSha256", self.ime_sha)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        package = self.source / "dist" / "ShapeKeySystem-9.8.7.zip"
        with zipfile.ZipFile(package) as archive:
            names = set(archive.namelist())
            self.assertEqual(names, {
                "ShapeKeySystem/modinfo.ini",
                "ShapeKeySystem/screenshot.jpg",
                "ShapeKeySystem/reframework/autorun/ShapeKeySystem.lua",
                "ShapeKeySystem/reframework/autorun/ShapeKeySystem_Core/Version.lua",
                "ShapeKeySystem/reframework/autorun/ShapeKeySystem_UI/Panel.lua",
                "ShapeKeySystem/reframework/autorun/ShapeKeySystem_Games/Registry.lua",
                "ShapeKeySystem/reframework/data/ShapeKeySystem/builtin/arkit.json",
                "ShapeKeySystem/reframework/data/ShapeKeySystem/faces/default.json",
                "ShapeKeySystem/reframework/images/ShapeKeySystem/faces/a.png",
                "ShapeKeySystem/natives/STM/GUI/ui_texture/tex_render/rtt_facemirror_00.rtex.6",
                "REF-IME/modinfo.ini",
                "REF-IME/reframework/plugins/REF-IME.dll",
            })
            main = archive.read("ShapeKeySystem/modinfo.ini")
            addon = archive.read("REF-IME/modinfo.ini")
            self.assertFalse(main.startswith(b"\xef\xbb\xbf"))
            main_lines = main.decode("utf-8").splitlines()
            addon_lines = addon.decode("utf-8").splitlines()
            self.assertIn("name=ShapeKeySystem", main_lines)
            self.assertIn("version=9.8.7", main_lines)
            self.assertIn("screenshot=screenshot.jpg", main_lines)
            self.assertIn("name=REF-IME", addon_lines)
            self.assertIn("version=1.2.3", addon_lines)
            self.assertIn("AddonFor=ShapeKeySystem", addon_lines)
            self.assertEqual(archive.read("REF-IME/reframework/plugins/REF-IME.dll"), b"dll bytes")

    def test_without_screenshot(self):
        result = self.run_package(screenshot=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        with zipfile.ZipFile(self.source / "dist" / "ShapeKeySystem-9.8.7.zip") as archive:
            self.assertNotIn("ShapeKeySystem/screenshot.jpg", archive.namelist())
            self.assertNotIn(b"screenshot=", archive.read("ShapeKeySystem/modinfo.ini"))

    def test_sha256_mismatch(self):
        result = self.run_package("-RefImeSha256", "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.source / "dist" / "ShapeKeySystem-9.8.7.zip").exists())


if __name__ == "__main__":
    unittest.main()

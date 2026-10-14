"""在独立目录验证部署迁移，不访问游戏安装目录或玩家文件。"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RecordingDeploymentTest(unittest.TestCase):
    """源仓库和游戏目录均由测试拥有，迁移只能删除已登记的旧内置文件。"""

    def test_recording_directory_migration(self):
        shell = shutil.which("pwsh") or shutil.which("powershell")
        if not shell:
            self.skipTest("PowerShell is required for deployment tests")
        with tempfile.TemporaryDirectory(prefix="sks_deploy_test_") as temporary:
            root = Path(temporary).resolve()
            source, target = root / "repo", root / "game"
            script = source / "tools" / "deploy.ps1"
            script.parent.mkdir(parents=True)
            shutil.copyfile(Path(__file__).resolve().parents[1] / "tools" / "deploy.ps1", script)
            target.mkdir()
            official = ("recording_catalog.json", "recordings/Speak.json", "recordings/CampMeals.json")
            preserved = {
                "data/ShapeKeySystem/games/mhwilds/recordings/Custom.json": b"custom recording",
                "data/ShapeKeySystem/user/recordings/User.json": b"user recording",
                "data/ShapeKeySystem/user/games/mhwilds/recordings/Legacy.json": b"legacy recording",
                "data/ShapeKeySystem/settings.json": b"player settings",
            }

            def put(base, relative, content):
                path = base / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            for suffix in official:
                put(source, "reframework/data/ShapeKeySystem/builtin/mhwilds/" + suffix, b"shipped data")
                put(target, "data/ShapeKeySystem/games/mhwilds/" + suffix, b"old shipped data")
            for relative, content in preserved.items():
                put(target, relative, content)
            environment = dict(os.environ, SKS_GAME_REFRAMEWORK=str(target))

            def run(*arguments):
                subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), *arguments],
                               env=environment, check=True, capture_output=True)

            run("-Check")
            for suffix in official:
                self.assertFalse((target / "data/ShapeKeySystem/builtin/mhwilds" / suffix).exists())
                self.assertTrue((target / "data/ShapeKeySystem/games/mhwilds" / suffix).exists())
            run()
            for suffix in official:
                self.assertEqual((target / "data/ShapeKeySystem/builtin/mhwilds" / suffix).read_bytes(), b"shipped data")
                self.assertFalse((target / "data/ShapeKeySystem/games/mhwilds" / suffix).exists())
            for relative, content in preserved.items():
                self.assertEqual((target / relative).read_bytes(), content)

            # Pull 不把已退出发布的旧目录重新引入源码，也不删除游戏中的旧文件。
            for suffix in official:
                put(target, "data/ShapeKeySystem/games/mhwilds/" + suffix, b"leftover")
            run("-Pull")
            self.assertFalse((source / "reframework/data/ShapeKeySystem/games").exists())
            for suffix in official:
                self.assertEqual((target / "data/ShapeKeySystem/games/mhwilds" / suffix).read_bytes(), b"leftover")


if __name__ == "__main__":
    unittest.main()

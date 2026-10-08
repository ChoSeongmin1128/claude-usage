import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]


class DMGMountOwnershipTests(unittest.TestCase):
    def test_existing_user_volume_is_never_detached_on_success_or_failure(self):
        for fails in [False, True]:
            with self.subTest(fails=fails), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scripts = root / "Scripts"
                (scripts / "lib").mkdir(parents=True)
                (scripts / "dmg-assets").mkdir()
                shutil.copy(ROOT / "Scripts/lib/app-identity.sh", scripts / "lib/app-identity.sh")
                (scripts / "dmg-assets/dmgbuild-settings.py").write_text("# isolated fixture\n")
                volume_root = root / "Volumes"
                volume = volume_root / "Install ClaudeUsage"
                volume.mkdir(parents=True)
                sentinel = volume / "user-data"
                sentinel.write_text("user mounted volume\n")
                source = (ROOT / "Scripts/make-dmg.sh").read_text()
                source = source.replace('"/Volumes/', '"' + str(volume_root) + '/')
                script = scripts / "make-dmg.sh"
                script.write_text(source)
                binaries = root / "bin"
                binaries.mkdir()
                trace = root / "mount-trace"
                trace.write_text("")
                helpers = {
                    "dmgbuild": '#!/bin/bash\nif [[ "${DMG_BUILD_FAIL:-0}" == 1 ]]; then exit 3; fi\n'
                        'for target in "$@"; do :; done\nprintf "fixture dmg" > "$target"\n',
                    "hdiutil": '#!/bin/bash\nprintf "%s\\n" "$*" >> "$MOUNT_TRACE"\n',
                }
                for name, contents in helpers.items():
                    binary = binaries / name
                    binary.write_text(contents)
                    binary.chmod(0o755)
                app = root / "ClaudeUsage.app"
                app.mkdir()
                output = root / "ClaudeUsage.dmg"
                result = subprocess.run(
                    ["/bin/bash", str(script)], capture_output=True, text=True,
                    env={**os.environ, "PATH": str(binaries) + ":/usr/bin:/bin",
                         "APP_PATH": str(app), "DMG_PATH": str(output), "CERT_HASH": "",
                         "VOLUME_ICON": str(root / "missing.icns"),
                         "BACKGROUND_PNG": str(root / "missing.png"),
                         "VOLUME_NAME": "Install ClaudeUsage", "MOUNT_TRACE": str(trace),
                         "DMG_BUILD_FAIL": "1" if fails else "0"})
                self.assertEqual(result.returncode == 0, not fails, result.stderr)
                self.assertEqual(trace.read_text(), "", "The builder detached a pre-existing user volume")
                self.assertEqual(sentinel.read_text(), "user mounted volume\n")
                self.assertEqual(output.exists(), not fails)


if __name__ == "__main__":
    unittest.main()

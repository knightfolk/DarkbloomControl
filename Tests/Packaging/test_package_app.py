import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'tools/package_app.py'


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.exe = self.root / 'binary'
        self.exe.write_bytes(b'fixture-executable')
        self.exe.chmod(0o755)
        self.resources = self.root / 'Resources.bundle'
        self.resources.mkdir()
        (self.resources / 'mark.svg').write_text('<svg/>')
        self.output = self.root / 'output'

    def run_packager(self, *extra):
        return subprocess.run([sys.executable, str(SCRIPT), '--executable', str(self.exe),
            '--resources', str(self.resources), '--output', str(self.output),
            '--version', '0.1.0', '--build-number', '1', *extra], capture_output=True, text=True)

    def test_bundle_and_manifest(self):
        result = self.run_packager()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / 'DarkbloomMonitor.app'
        binary = app / 'Contents/MacOS/DarkbloomMonitor'
        self.assertEqual(binary.read_bytes(), self.exe.read_bytes())
        self.assertTrue(binary.stat().st_mode & 0o111)
        self.assertFalse(binary.is_symlink())
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.darkbloom.monitor')
        self.assertEqual(info['CFBundleExecutable'], 'DarkbloomMonitor')
        self.assertEqual(info['CFBundleShortVersionString'], '0.1.0')
        self.assertEqual(info['CFBundleVersion'], '1')
        self.assertEqual(info['LSMinimumSystemVersion'], '14.0')
        self.assertTrue(info['LSUIElement'])
        self.assertEqual((app / 'Contents/Resources/DarkbloomMonitor_DarkbloomMonitor.bundle/mark.svg').read_text(), '<svg/>')
        manifest = json.loads((self.output / 'artifact-manifest.json').read_text())
        self.assertEqual(manifest['schema'], 1)
        self.assertEqual(manifest['purpose'], 'local-review')
        self.assertFalse(manifest['distribution_signed'])
        self.assertFalse(manifest['notarized'])
        files = manifest['files']
        actual = sorted(str(p.relative_to(app)) for p in app.rglob('*') if p.is_file())
        self.assertEqual([f['path'] for f in files], actual)
        for item in files:
            data = (app / item['path']).read_bytes()
            self.assertEqual(item['size_bytes'], len(data))
            self.assertEqual(item['sha256'], hashlib.sha256(data).hexdigest())
        self.assertNotIn(str(self.root), json.dumps(manifest))

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_text('untouched')
        self.assertNotEqual(self.run_packager().returncode, 0)
        self.assertEqual(marker.read_text(), 'untouched')
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_invalid_inputs_create_no_output(self):
        for extra in [('--version', '../bad'), ('--build-number', '0'),
                      ('--executable', str(self.root / 'missing')),
                      ('--executable', str(self.resources)),
                      ('--resources', str(self.exe))]:
            with self.subTest(extra=extra):
                self.assertNotEqual(self.run_packager(*extra).returncode, 0)
                self.assertFalse(self.output.exists())

    def test_resource_symlink_rejected(self):
        (self.resources / 'link').symlink_to(self.exe)
        self.assertNotEqual(self.run_packager().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_nonexecutable_rejected(self):
        self.exe.chmod(0o644)
        self.assertNotEqual(self.run_packager().returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()

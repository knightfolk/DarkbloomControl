import base64
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import importlib.util
from unittest.mock import patch

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
        (self.resources / 'AppIcon.icns').write_bytes(b'fixture-icon')
        self.output = self.root / 'output'

    def run_packager(self, *extra):
        return subprocess.run([sys.executable, str(SCRIPT), '--executable', str(self.exe),
            '--resources', str(self.resources), '--output', str(self.output),
            '--version', '0.1.0', '--build-number', '1', *extra], capture_output=True, text=True)

    def load_packager(self):
        spec = importlib.util.spec_from_file_location('packager_under_test', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_linked_sparkle_requires_embedded_framework(self):
        module = self.load_packager()
        with patch.object(module, '_macho_details', return_value=(True, [])):
            with self.assertRaisesRegex(ValueError, 'requires --sparkle-framework'):
                module.assemble(self.exe, self.resources, self.output, '1.0.0', '1')
        self.assertFalse(self.output.exists())

    def test_portable_lookup_removes_build_path_and_preserves_bundle_path(self):
        module = self.load_packager()
        bundle_path = '@executable_path/../Frameworks'
        with patch.object(module.subprocess, 'run') as run, patch.object(
            module, '_macho_details', return_value=(True, [bundle_path])):
            module._make_framework_lookup_portable(self.exe, ['/private/build/PackageFrameworks', bundle_path])
            self.assertEqual(run.call_args.args[0], ['/usr/bin/install_name_tool',
                '-delete_rpath', '/private/build/PackageFrameworks', str(self.exe)])

    def make_sparkle_framework(self):
        framework = self.root / 'Sparkle.framework'
        version = framework / 'Versions/A'
        version.mkdir(parents=True)
        (version / 'Sparkle').write_bytes(b'fixture-framework-binary')
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
        return framework

    def test_bundle_and_manifest(self):
        result = self.run_packager()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / 'Darkbloom Control.app'
        binary = app / 'Contents/MacOS/DarkbloomMonitor'
        self.assertEqual(binary.read_bytes(), self.exe.read_bytes())
        self.assertTrue(binary.stat().st_mode & 0o111)
        self.assertFalse(binary.is_symlink())
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.darkbloom.monitor')
        self.assertEqual(info['CFBundleName'], 'Darkbloom Control')
        self.assertEqual(info['CFBundleDisplayName'], 'Darkbloom Control')
        self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
        self.assertEqual((app / 'Contents/Resources/AppIcon.icns').read_bytes(), b'fixture-icon')
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

    def test_beta_bundle_uses_a_distinct_product_name_and_identifier(self):
        result = self.run_packager(
            '--app-name', 'DC Beta',
            '--bundle-identifier', 'dev.darkbloom.monitor.beta',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / 'DC Beta.app'
        self.assertTrue(app.is_dir())
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.darkbloom.monitor.beta')
        self.assertEqual(info['CFBundleName'], 'DC Beta')
        self.assertEqual(info['CFBundleDisplayName'], 'DC Beta')

    def test_beta_bundle_identity_rejects_path_components_and_invalid_ids(self):
        cases = [
            ('../DC Beta', 'dev.darkbloom.monitor.beta'),
            ('DC Beta', '../dev.darkbloom.beta'),
            ('DC Beta', 'not-a-domain'),
        ]
        for app_name, bundle_identifier in cases:
            with self.subTest(app_name=app_name, bundle_identifier=bundle_identifier):
                result = self.run_packager(
                    '--app-name', app_name,
                    '--bundle-identifier', bundle_identifier,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())

    def test_swiftpm_resource_bundle_keeps_its_bundle_structure(self):
        self.resources = self.root / 'DarkbloomMonitor_DarkbloomMonitor.bundle'
        bundle_resources = self.resources / 'Contents/Resources'
        bundle_resources.mkdir(parents=True)
        (bundle_resources / 'AppIcon.icns').write_bytes(b'fixture-icon')
        (bundle_resources / 'mark.svg').write_text('<svg/>')
        (self.resources / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundlePackageType': 'BNDL'})
        )

        result = self.run_packager()

        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / 'Darkbloom Control.app'
        nested_bundle = app / 'Contents/Resources/DarkbloomMonitor_DarkbloomMonitor.bundle'
        self.assertEqual(
            (nested_bundle / 'Contents/Info.plist').read_bytes(),
            (self.resources / 'Contents/Info.plist').read_bytes(),
        )
        self.assertEqual(
            (nested_bundle / 'Contents/Resources/mark.svg').read_text(),
            '<svg/>',
        )
        self.assertEqual(
            (app / 'Contents/Resources/AppIcon.icns').read_bytes(),
            b'fixture-icon',
        )

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

    def test_embeds_sparkle_with_safe_framework_symlinks_and_update_settings(self):
        framework = self.make_sparkle_framework()
        public_key = base64.b64encode(bytes(range(32))).decode('ascii')
        feed_url = 'https://updates.example.com/darkbloom/appcast.xml'

        result = self.run_packager('--sparkle-framework', str(framework),
            '--update-public-key', public_key, '--update-feed-url', feed_url)

        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / 'Darkbloom Control.app'
        embedded = app / 'Contents/Frameworks/Sparkle.framework'
        self.assertEqual((embedded / 'Versions/A/Sparkle').read_bytes(), b'fixture-framework-binary')
        self.assertTrue((embedded / 'Versions/Current').is_symlink())
        self.assertEqual((embedded / 'Versions/Current').readlink(), pathlib.Path('A'))
        self.assertTrue((embedded / 'Sparkle').is_symlink())
        self.assertEqual((embedded / 'Sparkle').readlink(), pathlib.Path('Versions/Current/Sparkle'))

        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['SUFeedURL'], feed_url)
        self.assertEqual(info['SUPublicEDKey'], public_key)
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertTrue(info['SUAllowsAutomaticUpdates'])

        manifest = json.loads((self.output / 'artifact-manifest.json').read_text())
        framework_relative = 'Contents/Frameworks/Sparkle.framework/'
        symlinks = [item for item in manifest['files']
                    if item['path'].startswith(framework_relative) and item.get('type') == 'symlink']
        self.assertEqual({item['path'] for item in symlinks}, {
            framework_relative + 'Sparkle',
            framework_relative + 'Versions/Current',
        })
        self.assertEqual({item['target'] for item in symlinks}, {
            'Versions/Current/Sparkle', 'A',
        })
        framework_binary = next(item for item in manifest['files']
                               if item['path'] == framework_relative + 'Versions/A/Sparkle')
        self.assertEqual(framework_binary['size_bytes'], len(b'fixture-framework-binary'))
        self.assertEqual(framework_binary['sha256'], hashlib.sha256(b'fixture-framework-binary').hexdigest())
        self.assertNotIn(str(self.root), json.dumps(manifest))

    def test_framework_without_release_configuration_is_allowed_but_has_no_feed(self):
        framework = self.make_sparkle_framework()

        result = self.run_packager('--sparkle-framework', str(framework))

        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.output / 'Darkbloom Control.app/Contents/Info.plist').read_bytes())
        self.assertNotIn('SUFeedURL', info)
        self.assertNotIn('SUPublicEDKey', info)
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertTrue(info['SUAllowsAutomaticUpdates'])

    def test_update_metadata_must_be_complete_and_belong_to_embedded_sparkle(self):
        public_key = base64.b64encode(bytes(range(32))).decode('ascii')
        cases = [
            ('--update-public-key', public_key),
            ('--update-feed-url', 'https://updates.example.com/appcast.xml'),
            ('--update-public-key', public_key, '--update-feed-url', 'https://updates.example.com/appcast.xml'),
        ]
        for extra in cases:
            with self.subTest(extra=extra):
                self.assertNotEqual(self.run_packager(*extra).returncode, 0)
                self.assertFalse(self.output.exists())

    def test_invalid_update_key_and_feed_are_rejected_before_output(self):
        framework = self.make_sparkle_framework()
        cases = [
            ('not-base64', 'https://updates.example.com/appcast.xml'),
            (base64.b64encode(b'short').decode('ascii'), 'https://updates.example.com/appcast.xml'),
            (base64.b64encode(bytes(range(32))).decode('ascii'), 'http://updates.example.com/appcast.xml'),
            (base64.b64encode(bytes(range(32))).decode('ascii'), 'https:///missing-host.xml'),
            (base64.b64encode(bytes(range(32))).decode('ascii'), 'https://user:password@updates.example.com/feed.xml'),
        ]
        for public_key, feed_url in cases:
            with self.subTest(feed_url=feed_url):
                result = self.run_packager('--sparkle-framework', str(framework),
                    '--update-public-key', public_key, '--update-feed-url', feed_url)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())

    def test_framework_rejects_external_and_dangling_symlink_targets(self):
        for link_target in [self.exe, pathlib.Path('../../outside')]:
            with self.subTest(link_target=link_target):
                framework = self.make_sparkle_framework()
                (framework / 'Versions/Current').unlink()
                (framework / 'Versions/Current').symlink_to(link_target)
                result = self.run_packager('--sparkle-framework', str(framework))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())
                shutil.rmtree(framework)

    def test_framework_path_must_be_absolute_and_a_sparkle_framework_directory(self):
        result = self.run_packager('--sparkle-framework', 'relative/Sparkle.framework')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

        result = self.run_packager('--sparkle-framework', str(self.resources))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()

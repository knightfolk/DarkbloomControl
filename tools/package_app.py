"""Assemble an unsigned local-review bundle. Never builds, launches or overwrites."""
import base64
import binascii
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys
import subprocess
from urllib.parse import urlsplit


def _validate_framework_tree(framework):
    if framework.is_symlink() or not framework.is_dir() or framework.name != 'Sparkle.framework':
        raise ValueError('Sparkle framework must be a non-symlink Sparkle.framework directory')
    root = framework.resolve(strict=True)
    for entry in framework.rglob('*'):
        mode = entry.lstat().st_mode
        if stat.S_ISLNK(mode):
            target = os.readlink(entry)
            if os.path.isabs(target):
                raise ValueError('Sparkle framework symlinks must be relative and stay inside the framework')
            try:
                resolved = (entry.parent / target).resolve(strict=False)
                resolved.relative_to(root)
            except (OSError, RuntimeError, ValueError):
                raise ValueError('Sparkle framework symlinks must stay inside the framework') from None
        elif not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('Sparkle framework cannot contain special files')


def _validate_update_settings(sparkle_framework, public_key, feed_url):
    if (public_key is None) != (feed_url is None):
        raise ValueError('update public key and feed URL must be supplied together')
    if public_key is not None and sparkle_framework is None:
        raise ValueError('update settings require an embedded Sparkle framework')
    if public_key is not None:
        try:
            decoded = base64.b64decode(public_key, validate=True)
        except (binascii.Error, ValueError):
            raise ValueError('update public key must be base64-encoded Ed25519 key material') from None
        if len(decoded) != 32 or base64.b64encode(decoded).decode('ascii') != public_key:
            raise ValueError('update public key must be canonical base64 for a 32-byte Ed25519 key')

        if feed_url != feed_url.strip() or any(ord(character) < 0x20 or character.isspace() for character in feed_url):
            raise ValueError('update feed URL must be a valid HTTPS URL')
        try:
            parts = urlsplit(feed_url)
            _ = parts.port
        except ValueError:
            raise ValueError('update feed URL must be a valid HTTPS URL') from None
        if (parts.scheme.lower() != 'https' or not parts.hostname
                or parts.username is not None or parts.password is not None or parts.fragment):
            raise ValueError('update feed URL must be a valid HTTPS URL without credentials or fragments')


def _manifest_entries(app, framework_destination):
    files = []
    framework_relative = framework_destination.relative_to(app) if framework_destination else None
    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app)
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            if framework_relative is None or not relative.is_relative_to(framework_relative):
                raise ValueError('resource changed during copy; partial output is not valid')
            files.append(dict(path=str(relative), type='symlink', target=os.readlink(path)))
        elif stat.S_ISREG(mode):
            data = path.read_bytes()
            files.append(dict(path=str(relative), size_bytes=len(data),
                              sha256=hashlib.sha256(data).hexdigest()))
        elif not stat.S_ISDIR(mode):
            raise ValueError('resource changed during copy; partial output is not valid')
    return files



def _macho_details(executable):
    # Fixture/non-Mach-O inputs remain supported by the packaging unit tests.
    with executable.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (bytes.fromhex(value) for value in
                     ('cffaedfe', 'feedfacf', 'cefaedfe', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')):
        return False, []
    dependencies = subprocess.run(['/usr/bin/otool', '-L', str(executable)],
                                  check=True, capture_output=True, text=True).stdout
    load_commands = subprocess.run(['/usr/bin/otool', '-l', str(executable)],
                                   check=True, capture_output=True, text=True).stdout
    rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', load_commands)
    return 'Sparkle.framework/' in dependencies, list(dict.fromkeys(rpaths))


def _make_framework_lookup_portable(executable, rpaths):
    args = ['/usr/bin/install_name_tool']
    for path in rpaths:
        if path.startswith('/'):
            args.extend(['-delete_rpath', path])
    if '@executable_path/../Frameworks' not in rpaths:
        args.extend(['-add_rpath', '@executable_path/../Frameworks'])
    if len(args) > 1:
        subprocess.run(args + [str(executable)], check=True, capture_output=True, text=True)
    _, remaining = _macho_details(executable)
    if any(path.startswith('/') for path in remaining):
        raise ValueError('packaged executable retains an absolute framework search path')
    if '@executable_path/../Frameworks' not in remaining:
        raise ValueError('packaged executable is missing its in-app framework search path')

def assemble(executable, resources, output, version, build_number,
             sparkle_framework=None, update_public_key=None, update_feed_url=None):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('version must be three numeric components')
    if not re.fullmatch(r'[1-9]\d*', build_number):
        raise ValueError('build number must be a positive integer')
    if not all(p.is_absolute() for p in (executable, resources, output)):
        raise ValueError('all paths must be absolute')
    if sparkle_framework is not None:
        if not sparkle_framework.is_absolute():
            raise ValueError('Sparkle framework path must be absolute')
        _validate_framework_tree(sparkle_framework)
    _validate_update_settings(sparkle_framework, update_public_key, update_feed_url)
    if executable.is_symlink() or not executable.is_file():
        raise ValueError('executable must be a regular non-symlink file')
    if not executable.stat().st_mode & 0o111:
        raise ValueError('executable must have executable permissions')
    links_sparkle, rpaths = _macho_details(executable)
    if links_sparkle and sparkle_framework is None:
        raise ValueError("this executable requires --sparkle-framework")
    if resources.is_symlink() or not resources.is_dir():
        raise ValueError('resources must be a non-symlink directory')
    for entry in resources.rglob('*'):
        mode = entry.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('resources cannot contain symlinks or special files')
    if not (resources / 'AppIcon.icns').is_file():
        raise ValueError('resources must contain the Darkbloom Control app icon')
    if output.is_relative_to(resources) or resources.is_relative_to(output):
        raise ValueError('output and resource paths must not overlap')
    if sparkle_framework is not None:
        if output.is_relative_to(sparkle_framework) or sparkle_framework.is_relative_to(output):
            raise ValueError('output and Sparkle framework paths must not overlap')
    # Exclusive creation protects existing outputs, including empty directories.
    # Failures after this point deliberately leave the new partial output intact.
    output.mkdir()
    app = output / 'Darkbloom Control.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    shutil.copy2(executable, contents / 'MacOS/DarkbloomMonitor')
    if links_sparkle:
        _make_framework_lookup_portable(contents / 'MacOS/DarkbloomMonitor', rpaths)
    shutil.copytree(resources, contents / 'Resources/DarkbloomMonitor_DarkbloomMonitor.bundle', symlinks=True)
    shutil.copy2(resources / 'AppIcon.icns', contents / 'Resources/AppIcon.icns')
    framework_destination = None
    if sparkle_framework is not None:
        framework_destination = contents / 'Frameworks/Sparkle.framework'
        framework_destination.parent.mkdir()
        shutil.copytree(sparkle_framework, framework_destination, symlinks=True)
        # Verify the copied links too, so a source tree change during copy cannot
        # turn a local framework into a bundle path escape.
        _validate_framework_tree(framework_destination)
    # Preserve identity and executable/resource names for upgrade compatibility.
    info = dict(CFBundleIdentifier='dev.darkbloom.monitor', CFBundleName='Darkbloom Control',
                CFBundleDisplayName='Darkbloom Control',
                CFBundleIconFile='AppIcon',
                CFBundleExecutable='DarkbloomMonitor', CFBundlePackageType='APPL',
                CFBundleShortVersionString=version, CFBundleVersion=build_number,
                LSMinimumSystemVersion='14.0', LSUIElement=True)
    if sparkle_framework is not None:
        info.update(SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                    SUAllowsAutomaticUpdates=True)
        if update_public_key is not None:
            info.update(SUFeedURL=update_feed_url, SUPublicEDKey=update_public_key)
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    files = _manifest_entries(app, framework_destination)
    manifest = dict(schema=1, purpose='local-review', distribution_signed=False,
                    notarized=False, files=files)
    (output / 'artifact-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('executable', 'resources', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--sparkle-framework', type=Path,
                        help='absolute Sparkle.framework path; required when the executable links Sparkle')
    parser.add_argument('--update-public-key',
                        help='base64-encoded 32-byte Ed25519 Sparkle public key')
    parser.add_argument('--update-feed-url', help='HTTPS Sparkle appcast URL')
    args = parser.parse_args()
    try:
        print(assemble(**vars(args)))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Packaging failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

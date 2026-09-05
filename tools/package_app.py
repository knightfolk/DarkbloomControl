"""Assemble an unsigned local-review bundle. Never builds, launches or overwrites."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys


def assemble(executable, resources, output, version, build_number):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('version must be three numeric components')
    if not re.fullmatch(r'[1-9]\d*', build_number):
        raise ValueError('build number must be a positive integer')
    if not all(p.is_absolute() for p in (executable, resources, output)):
        raise ValueError('all paths must be absolute')
    if executable.is_symlink() or not executable.is_file():
        raise ValueError('executable must be a regular non-symlink file')
    if not executable.stat().st_mode & 0o111:
        raise ValueError('executable must have executable permissions')
    if resources.is_symlink() or not resources.is_dir():
        raise ValueError('resources must be a non-symlink directory')
    for entry in resources.rglob('*'):
        mode = entry.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('resources cannot contain symlinks or special files')
    if output.is_relative_to(resources) or resources.is_relative_to(output):
        raise ValueError('output and resource paths must not overlap')
    # Exclusive creation protects existing outputs, including empty directories.
    # Failures after this point deliberately leave the new partial output intact.
    output.mkdir()
    app = output / 'DarkbloomMonitor.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    shutil.copy2(executable, contents / 'MacOS/DarkbloomMonitor')
    shutil.copytree(resources, contents / 'Resources/DarkbloomMonitor_DarkbloomMonitor.bundle', symlinks=True)
    info = dict(CFBundleIdentifier='dev.darkbloom.monitor', CFBundleName='DarkbloomMonitor',
                CFBundleExecutable='DarkbloomMonitor', CFBundlePackageType='APPL',
                CFBundleShortVersionString=version, CFBundleVersion=build_number,
                LSMinimumSystemVersion='14.0', LSUIElement=True)
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    files = []
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            raise ValueError('resource changed during copy; partial output is not valid')
        if path.is_file():
            data = path.read_bytes()
            files.append(dict(path=str(path.relative_to(app)), size_bytes=len(data),
                              sha256=hashlib.sha256(data).hexdigest()))
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
    args = parser.parse_args()
    try:
        print(assemble(**vars(args)))
    except (OSError, ValueError) as error:
        print(f'Packaging failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

"""Run only the opt-in synthetic native viewer test in an independently named app.

Build ImageAllTests first. During this run, operate the displayed viewer using the
normal UI (play, seek, choose 1.5x). Create <evidence>/finish when done. The test
checks observations and releases the player. It times out after five minutes.
No production ImageAll entry point, Photos host, or real media is launched.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True, help='New, empty output directory')
    args = parser.parse_args()
    products, evidence = args.products.resolve(), args.evidence.resolve()
    host = products / 'ImageAll.app/Contents'
    bundle = host / 'PlugIns/ImageAllTests.xctest'
    dylib = host / 'MacOS/ImageAll.debug.dylib'
    if not bundle.is_dir() or not dylib.is_file():
        parser.error('Build-for-testing products are missing')
    if evidence.exists() and any(evidence.iterdir()):
        parser.error('Use a new empty evidence directory; previous evidence is preserved')
    evidence.mkdir(parents=True, exist_ok=True)
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    platform = developer / 'Platforms/MacOSX.platform/Developer'
    app = evidence / 'VideoUITestRunner.app'
    executable = app / 'Contents/MacOS/VideoUITestRunner'
    executable.parent.mkdir(parents=True)
    shutil.copy2(developer / 'usr/bin/xctest', executable)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.gwlee.ImageAll.synthetic-video-test',
        'CFBundleExecutable': executable.name, 'CFBundleName': 'VideoUITestRunner',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'NSHighResolutionCapable': True,
    }))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    temporary = evidence / 'tmp'
    temporary.mkdir()
    environment = os.environ.copy()
    environment.update({
        'TMPDIR': str(temporary), 'IMAGEALL_INTERACTIVE_VIDEO_EVIDENCE': str(evidence),
        'DYLD_FRAMEWORK_PATH': str(platform / 'Library/Frameworks'),
        'DYLD_LIBRARY_PATH': str(platform / 'usr/lib'),
        'DYLD_INSERT_LIBRARIES': str(dylib), 'LLVM_PROFILE_FILE': str(temporary / '%p.profraw'),
    })
    print(f'Synthetic viewer: {app}\nFinish marker: {evidence / "finish"}', flush=True)
    with (evidence / 'tests.log').open('w') as log:
        result = subprocess.run([str(executable), '-XCTest',
            'ImageAllTests.LibraryVideoViewingTests/testInteractiveNativeVideoViewerWhenRequested',
            str(bundle)], env=environment, stdout=log, stderr=subprocess.STDOUT)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())

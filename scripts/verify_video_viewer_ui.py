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
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True, help='New, empty output directory')
    parser.add_argument('--with-audio', action='store_true', help='Generate a quiet synthetic tone and require volume/mute checks')
    parser.add_argument('--require-focus', action='store_true', help='Also require an actual app focus loss and return; background AX operations do not prove this')
    parser.add_argument('--story-clip', action='store_true', help='Operate the real story clip editor: 0.2 to 0.8 seconds, gain 30%%, then Use Clip')
    parser.add_argument('--story-workspace', action='store_true', help='Operate mixed story add/edit/order/save controls, then create finish')
    args = parser.parse_args()
    if (args.story_clip or args.story_workspace) and (args.with_audio or args.require_focus) or (args.story_clip and args.story_workspace):
        parser.error('Story clip mode cannot be combined with viewer options')
    products, evidence = args.products.resolve(), args.evidence.resolve()
    host = products / 'ImageAll.app/Contents'
    bundle = host / 'PlugIns/ImageAllTests.xctest'
    dylib = host / 'MacOS/ImageAll.debug.dylib'
    if not bundle.is_dir() or not dylib.is_file():
        parser.error('Build-for-testing products are missing')
    if evidence.exists() and any(evidence.iterdir()):
        parser.error('Use a new empty evidence directory; previous evidence is preserved')
    evidence.mkdir(parents=True, exist_ok=True)
    if args.with_audio:
        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            parser.error('FFmpeg is required for the synthetic audio fixture')
        subprocess.run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30:duration=30',
            '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=30',
            '-af', 'volume=0.03', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-shortest', str(evidence / 'synthetic-audio.mp4')], check=True)
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    platform = developer / 'Platforms/MacOSX.platform/Developer'
    app = evidence / 'VideoUITestRunner.app'
    executable = app / 'Contents/MacOS/VideoUITestRunner'
    executable.parent.mkdir(parents=True)
    shutil.copy2(developer / 'usr/bin/xctest', executable)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.gwlee.ImageAll.synthetic-video-test.' + uuid.uuid4().hex,
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
    if args.with_audio:
        environment['IMAGEALL_INTERACTIVE_VIDEO_WITH_AUDIO'] = '1'
    if args.require_focus:
        environment['IMAGEALL_INTERACTIVE_VIDEO_REQUIRE_FOCUS'] = '1'
    if args.story_clip:
        environment.pop('IMAGEALL_INTERACTIVE_VIDEO_EVIDENCE', None)
        environment['IMAGEALL_INTERACTIVE_STORY_CLIP_EVIDENCE'] = str(evidence)
    if args.story_workspace:
        environment.pop('IMAGEALL_INTERACTIVE_VIDEO_EVIDENCE', None)
        environment['IMAGEALL_INTERACTIVE_STORY_WORKSPACE_EVIDENCE'] = str(evidence)
        environment['IMAGEALL_VIDEO_EVIDENCE_DIR'] = str(evidence)
    selector = ('ImageAllTests.TimeStoryFeatureTests/testWorkspaceVideoClipRequestApplyAndPhotoDurationProtection'
        if args.story_clip else 'ImageAllTests.LibraryVideoViewingTests/testInteractiveNativeVideoViewerWhenRequested')
    if args.story_workspace:
        selector = 'ImageAllTests.TimeStoryFeatureTests/testWorkspaceMixedStoryEditSaveReopenAndRender'
    completion = 'Click Use Clip after entering the requested range and gain' if args.story_clip else f'Finish marker: {evidence / "finish"}'
    print(f'Synthetic viewer: {app}\n{completion}', flush=True)
    with (evidence / 'tests.log').open('w') as log:
        result = subprocess.run([str(executable), '-XCTest',
            selector,
            str(bundle)], env=environment, stdout=log, stderr=subprocess.STDOUT)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())

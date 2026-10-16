"""Prepare an internal-volume, LaunchServices-started synthetic XCTest app.

This does not launch the app or the ImageAll production entry point. Use CUA to
open the returned app, operate its synthetic window, then create evidence/finish.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('mode', choices=['external', 'slimming'])
parser.add_argument('--products', type=Path, required=True)
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
evidence = Path(tempfile.mkdtemp(prefix=f'imageall-native-{args.mode}-20261016-'))
app = evidence / 'ImageAllVideoAcceptance.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True)
resources = app / 'Contents/Resources'
resources.mkdir()
temporary = evidence / 'tmp'
temporary.mkdir()
original = args.products.resolve() / 'ImageAll.app/Contents'
bundle = app / 'Contents/PlugIns/ImageAllTests.xctest'
shutil.copytree(original / 'PlugIns/ImageAllTests.xctest', bundle, symlinks=True)
frameworks = app / 'Contents/Frameworks'
shutil.copytree(args.products.resolve() / 'PackageFrameworks', frameworks, symlinks=True)
library = macos / 'ImageAll.debug.dylib'
shutil.copy2(original / 'MacOS/ImageAll.debug.dylib', library)
fixture = resources / 'synthetic-video.mp4'
shutil.copy2(args.source / 'docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4', fixture)
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
platform = developer / 'Platforms/MacOSX.platform/Developer'
executor = macos / 'TestExecutor'
shutil.copy2(developer / 'usr/bin/xctest', executor)
selector = ('ImageAllTests.LibraryVideoViewingTests/testInteractiveCloudOrExternalVideoWhenRequested'
    if args.mode == 'external' else
    'ImageAllTests.LibrarySlimmingRecycleTests/testInteractiveVideoSlimmingWhenRequested')
key = ('IMAGEALL_INTERACTIVE_CLOUD_EXTERNAL_EVIDENCE' if args.mode == 'external'
    else 'IMAGEALL_INTERACTIVE_SLIMMING_EVIDENCE')
environment = {
    key: str(evidence),
    'IMAGEALL_SYNTHETIC_VIDEO_FIXTURE': str(fixture),
    'TMPDIR': str(temporary),
    'DYLD_FRAMEWORK_PATH': str(frameworks) + ':' + str(platform / 'Library/Frameworks'),
    'DYLD_LIBRARY_PATH': str(macos) + ':' + str(platform / 'usr/lib'),
    'DYLD_INSERT_LIBRARIES': str(library),
    'LLVM_PROFILE_FILE': str(temporary / '%p.profraw'),
}
literal = json.dumps
assignments = '\n'.join(f'setenv({literal(k)}, {literal(v)}, 1);' for k, v in environment.items())
c = evidence / 'launcher.c'
c.write_text(f'''#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <stdio.h>
int main(void) {{
int fd = open({literal(str(evidence / 'tests.log'))}, O_WRONLY|O_CREAT|O_TRUNC, 0600);
if (fd < 0) return 101;
dup2(fd, 1); dup2(fd, 2); close(fd);
{assignments}
fprintf(stderr, "Native synthetic XCTest launcher PID %d\\n", getpid());
execl({literal(str(executor))}, {literal(str(executor))}, "-XCTest",
    {literal(selector)}, {literal(str(bundle))}, (char *)0);
perror("exec XCTest"); return 102;
}}
''')
executable = macos / 'ImageAllVideoAcceptance'
subprocess.run(['/usr/bin/clang', str(c), '-o', str(executable)], check=True)
identifier = 'com.gwlee.ImageAll.native-synthetic.' + uuid.uuid4().hex
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': identifier,
    'CFBundleExecutable': executable.name,
    'CFBundleName': 'ImageAll Video Acceptance',
    'CFBundleDisplayName': 'ImageAll Video Acceptance',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'LSBackgroundOnly': False,
    'NSHighResolutionCapable': True,
}))
subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
manifest = {
    'mode': args.mode, 'evidence': str(evidence), 'app': str(app),
    'identifier': identifier, 'selector': selector,
    'source': str(args.source),
    'appDylibSHA256': hashlib.sha256(library.read_bytes()).hexdigest(),
    'testExecutableSHA256': hashlib.sha256((bundle / 'Contents/MacOS/ImageAllTests').read_bytes()).hexdigest(),
    'fixtureSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
    'scope': 'private synthetic media, temporary database, direct XCTest; no production entry point',
}
(evidence / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))

#!/usr/bin/env python3
"""Direct XCTest: synthetic mobile task -> HTTP -> Mac catalog, no app host."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts/usb-memory-regression"))
from run import Usage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True, help="Current macOS Debug products")
    parser.add_argument("--build-log", type=Path, required=True, help="Matching successful Mac xcodebuild log")
    parser.add_argument("--output", type=Path, required=True, help="New synthetic output directory")
    parser.add_argument("--device-config", type=Path, help="Physical USB acceptance config directory; interactive 30 minute host")
    parser.add_argument("--handoff", action="store_true", help="Mac-owned detached handoff acceptance")
    parser.add_argument("--handoff-mib", type=int, default=16)
    parser.add_argument("--handoff-items", type=int, default=1)
    parser.add_argument("--handoff-target", type=Path, help="New HDD2 ImageAll-USB-Synthetic-* directory only")
    parser.add_argument("--handoff-prepare-only", action="store_true")
    parser.add_argument("--handoff-restart", type=Path)
    args = parser.parse_args()
    if args.handoff_restart: args.handoff = True
    if args.handoff_target:
        t = args.handoff_target.absolute()
        if t.exists() or t.is_symlink() or t.parent.resolve() != Path("/Volumes/HDD2") or not t.name.startswith("ImageAll-USB-Synthetic-"):
            parser.error("target must be a NEW explicitly synthetic top-level HDD2 directory, never user data")
    output = args.output.absolute()
    if output.is_symlink() or output.resolve().is_relative_to("/Volumes/HDD2"):
        parser.error("output must be a new task-owned directory outside protected HDD2")
    output.mkdir(parents=True, exist_ok=False)
    (output / "SYNTHETIC-ONLY").write_text("Generated metadata and bytes; no Photos or production database.\n")
    products = args.products.resolve()
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    framework = platform / "Library/Frameworks"
    binary = products / "ImageAll.app/Contents/MacOS/ImageAll.debug.dylib"
    imports = []
    for line in args.build_log.read_text().splitlines():
        if "builtin-SwiftDriver --" in line and "-module-name ImageAll " in line:
            argv = shlex.split(line)
            for i, arg in enumerate(argv[:-1]):
                if arg in ("-I", "-F") or (arg == "-Xcc" and argv[i + 1].startswith("-fmodule-map-file=")):
                    imports.extend([arg, argv[i + 1]])
            break
    if not imports or not binary.is_file():
        parser.error("matching built Mac module, dylib and SwiftDriver log are required")
    env = {k: os.environ[k] for k in ("HOME", "TMPDIR", "PATH", "LANG", "DEVELOPER_DIR") if k in os.environ}
    module = output / "ClientModule"
    module.mkdir()
    client_sources = sorted((REPO / "Packages/ImageAllRemoteClient/Sources/ImageAllRemoteClient").glob("*.swift"))
    common = ["xcrun", "swiftc", "-target", "arm64-apple-macos15.0", "-I", str(products),
              "-I", str(products / "Modules")]

    def compile_with_log(command, name):
        (output / (name + "-command.json")).write_text(json.dumps(command, indent=2))
        with (output / (name + ".log")).open("w") as log:
            subprocess.run(command, cwd=REPO, env=env, stdout=log, stderr=log, check=True)

    compile_with_log(common + ["-emit-module", "-emit-object", "-whole-module-optimization",
        "-swift-version", "6", "-module-name", "ImageAllRemoteClient",
        "-emit-module-path", str(module / "ImageAllRemoteClient.swiftmodule"),
        "-o", str(module / "ImageAllRemoteClient.o")] + list(map(str, client_sources)), "client-build")
    bundle = output / "ImportTaskE2E.xctest"
    executable = bundle / "Contents/MacOS/ImportTaskE2E"
    executable.parent.mkdir(parents=True)
    sources = [
        "ImageAllTests/Database/CatalogSchemaExpectations.swift",
        "ImageAllTests/Database/DatabaseTestSupport.swift",
        "ImageAllTests/Jobs/JobTestDoubles.swift",
        "ImageAllTests/Reconcile/FolderReconcileTestSupport.swift",
        "ImageAllTests/Remote/RemoteHTTPServerTests.swift",
        "ImageAllMobile/App/LocalSharePresentation.swift",
        "scripts/mobile/MacOwnedHandoffTests.swift" if args.handoff else ("scripts/mobile/USBImportDeviceHostTests.swift" if args.device_config else "scripts/mobile/ImportTaskEndToEndTests.swift"),
    ]
    # Prefer the freshly compiled client over any older client module left in
    # macOS products (the shipping client is primarily built for iOS).
    compile_with_log(common[:2] + ["-I", str(module)] + common[2:] +
        ["-emit-library", "-profile-generate", "-enable-testing",
        "-module-name", "ImportTaskE2E", "-F", str(framework),
        "-F", str(products / "PackageFrameworks"), "-framework", "XCTest",
        "-I", str(platform / "usr/lib"), "-L", str(platform / "usr/lib"),
        "-Xlinker", "-rpath", "-Xlinker", str(platform / "usr/lib"),
        "-Xlinker", "-rpath", "-Xlinker", str(framework),
        "-Xlinker", "-rpath", "-Xlinker", str(binary.parent)] + imports + sources +
        [str(binary), str(module / "ImageAllRemoteClient.o"), "-o", str(executable)], "test-build")
    fingerprints = {}
    for path in [REPO / s for s in sources] + client_sources + [binary, executable]:
        fingerprints[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / "fingerprints.json").write_text(json.dumps(fingerprints, indent=2))
    env.update(IMAGEALL_SYNTHETIC_ROOT=str(output),
               LLVM_PROFILE_FILE=str(output / "test-%p.profraw"),
               DYLD_FRAMEWORK_PATH=str(products / "PackageFrameworks") + ":" + str(framework))
    if args.device_config:
        env["IMAGEALL_DEVICE_CONFIG"] = str(args.device_config.resolve())
    env["IMAGEALL_HANDOFF_MIB"] = str(args.handoff_mib)
    env["IMAGEALL_HANDOFF_ITEMS"] = str(args.handoff_items)
    if args.handoff_target: env["IMAGEALL_HANDOFF_TARGET"] = str(args.handoff_target.absolute())
    if args.handoff_prepare_only: env["IMAGEALL_HANDOFF_PREPARE_ONLY"] = "1"
    if args.handoff_restart: env["IMAGEALL_HANDOFF_EXISTING"] = str(args.handoff_restart.absolute())
    selection = "ImportTaskE2E.RemoteHTTPServerTests/" + ("testMacOwnedColdResume" if args.handoff_restart else ("testMacOwnedHandoffWithoutConnection" if args.handoff else ("testPhysicalUSBImportTask" if args.device_config else "testImportTaskHTTPPauseResumePublishAndDamage")))
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    started = time.monotonic()
    peak = rss = 0
    reason = None
    with (output / "test.log").open("w") as log:
        child = subprocess.Popen(["xcrun", "xctest", "-XCTest", selection, str(bundle)],
                                 cwd=REPO, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            while child.poll() is None:
                usage = Usage()
                if lib.proc_pid_rusage(child.pid, 2, ctypes.byref(usage)) == 0:
                    peak = max(peak, usage.footprint)
                    rss = max(rss, usage.resident)
                    if max(usage.footprint, usage.resident) > 512 * 1024**2:
                        reason = "memory-limit"
                elif child.poll() is None:
                    reason = "monitor-unavailable"
                if time.monotonic() - started > (1800 if args.device_config or args.handoff else 180):
                    reason = "timeout"
                if reason:
                    os.killpg(child.pid, signal.SIGKILL)
                    break
                (output / "guard.json").write_text(json.dumps(dict(pid=child.pid, peak_footprint_bytes=peak, peak_rss_bytes=rss, limit_mib=512, stop_reason=reason)))
                time.sleep(.1 if args.device_config else .01)
            code = child.wait(timeout=5)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    passed = code == 0 and reason is None and (output / "scenario-result.json").is_file()
    passed = passed and "Executed 1 test, with 0 failures" in (output / "test.log").read_text()
    result = dict(passed=passed, exit_code=code, stop_reason=reason, limit_mib=512,
                  peak_footprint_bytes=peak, peak_rss_bytes=rss, seconds=time.monotonic() - started)
    (output / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

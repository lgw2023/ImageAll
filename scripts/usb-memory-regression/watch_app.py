#!/usr/bin/env python3
"""Observe exactly one current Xcode App process; never launch or restart it."""
import argparse, ctypes, json, os, pathlib, signal, subprocess, time
from run import Usage

p = argparse.ArgumentParser()
p.add_argument('executable', type=pathlib.Path)
p.add_argument('report', type=pathlib.Path)
p.add_argument('--limit-mib', type=int, default=1024)
a = p.parse_args()
if not 32 <= a.limit_mib <= 1024: p.error('limit must be 32...1024 MiB')
expected = str(a.executable.resolve())
if not expected.endswith('/ImageAll.app/Contents/MacOS/ImageAll'):
    p.error('requires the exact ImageAll executable path')
a.report.parent.mkdir(parents=True, exist_ok=True)
lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
limit = a.limit_mib * 1024**2
started = time.monotonic(); peak = rss_peak = 0; observed = None; count = 0

def identity(pid):
    buf = ctypes.create_string_buffer(4096)
    return lib.proc_pidpath(pid, buf, len(buf)) > 0 and os.fsdecode(buf.value) == expected

def save(state, **extra):
    record = dict(state=state, pid=observed, guard_pid=os.getpid(), limit_bytes=limit,
        updated_at=time.time(), peak_footprint_bytes=peak, peak_rss_bytes=rss_peak,
        seconds=time.monotonic()-started, samples=count, **extra)
    temp = a.report.with_suffix('.tmp')
    temp.write_text(json.dumps(record, indent=2)); temp.replace(a.report)

def stop(reason):
    # Never signal a reused PID or another build.
    if identity(observed):
        os.kill(observed, signal.SIGTERM)
        for _ in range(20):
            if not identity(observed): break
            time.sleep(.1)
        if identity(observed): os.kill(observed, signal.SIGKILL)
    save('stopped', reason=reason)

save('waiting-for-exact-app')
while observed is None and time.monotonic()-started < 1800:
    result = subprocess.run(['/usr/bin/pgrep', '-x', 'ImageAll'], capture_output=True, text=True)
    matches = [int(x) for x in result.stdout.split() if x.isdigit() and identity(int(x))]
    if len(matches) == 1: observed = matches[0]
    elif len(matches) > 1:
        save('refused-multiple-matching-processes'); raise SystemExit(1)
    else: time.sleep(.2)
if observed is None:
    save('no-app-started'); raise SystemExit(1)

save('watching')
with a.report.with_suffix('.jsonl').open('a', buffering=1) as timeline:
    while identity(observed):
        usage = Usage()
        if lib.proc_pid_rusage(observed, 2, ctypes.byref(usage)) != 0:
            if identity(observed):
                stop('memory-monitor-unavailable'); raise SystemExit(1)
            break
        count += 1; peak = max(peak, usage.footprint); rss_peak = max(rss_peak, usage.resident)
        if max(usage.footprint, usage.resident) > limit:
            stop('memory-limit'); raise SystemExit(1)
        if count % 20 == 0:
            save('watching', current_footprint_bytes=usage.footprint, current_rss_bytes=usage.resident)
            timeline.write(json.dumps(dict(at=time.time(), footprint=usage.footprint, rss=usage.resident))+'\n')
        time.sleep(.05)
save('app-exited')

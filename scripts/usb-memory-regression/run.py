#!/usr/bin/env python3
"""Synthetic-only cold recovery with an independent physical-memory kill guard."""
import argparse, ctypes, hashlib, json, os, pathlib, signal, subprocess, time, uuid

class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(x, ctypes.c_uint64) for x in (
        'user', 'system', 'wakeups', 'interrupts', 'pageins', 'wired', 'resident',
        'footprint', 'start', 'exit', 'child_user', 'child_system', 'child_wakeups',
        'child_interrupts', 'child_pageins', 'child_elapsed', 'disk_read', 'disk_write')]

def fixture(root, count, chunks_per_file=2, archive=False):
    # This runner creates a NEW owned directory; it never accepts an existing dataset.
    root.mkdir(parents=True, exist_ok=False)
    (root / 'SYNTHETIC-ONLY').write_text('Generated zeros, no user media.\n')
    migration, device = str(uuid.uuid4()), str(uuid.uuid4())
    package = root / ('.imageall-transfer-' + migration) / 'package'
    (package / 'resources').mkdir(parents=True)
    chunk_size = 4 * 1024**2
    chunk_hash = hashlib.sha256(bytes(chunk_size)).hexdigest()
    digest = hashlib.sha256()
    for _ in range(chunks_per_file): digest.update(bytes(chunk_size))
    file_hash = digest.hexdigest()
    chunks, receipts = {}, {}
    for _ in range(count):
        rel = 'resources/' + str(uuid.uuid4()) + '.bin'
        with (package / rel).open('wb') as f: f.truncate(chunks_per_file * chunk_size)
        chunks[rel] = [dict(offset=i * chunk_size, byteCount=chunk_size, sha256=chunk_hash) for i in range(chunks_per_file)]
        receipts[rel] = dict(migrationID=migration, deviceID=device,
            resource=dict(relativePath=rel, byteCount=chunks_per_file * chunk_size, sha256=file_hash))
    total_bytes = count * chunks_per_file * chunk_size
    if archive:
        records = [dict(recordType='header', formatVersion=1, migrationID=migration,
            sourceDeviceID=device, sourceEpoch=str(uuid.uuid4()), scopeRevision=1,
            inventoryWatermark=1, declaredItemCount=count)]
        for i, rel in enumerate(chunks):
            records.append(dict(recordType='item', mediaID=str(uuid.uuid4()),
                sourceLocalIdentifier='synthetic-' + str(i), mediaKind='image',
                observedFavorite=False, factRevision=1, tagDecisions=[], collections=[], appleAlbums=[],
                resources=[dict(id=pathlib.Path(rel).stem, role='original', version=1,
                    uniformTypeIdentifier='public.data', required=True, status='present',
                    relativePath=rel, byteCount=chunks_per_file * chunk_size, sha256=file_hash)]))
        manifest = ''.join(json.dumps(r) + '\n' for r in records).encode()
        (package / 'manifest.jsonl').write_bytes(manifest)
        chunks['manifest.jsonl'] = [dict(offset=i, byteCount=len(manifest[i:i+chunk_size]),
            sha256=hashlib.sha256(manifest[i:i+chunk_size]).hexdigest())
            for i in range(0, len(manifest), chunk_size)]
        total_bytes += len(manifest)
        # Simulate a crash after data write but before its journal commit.
        with (package / next(iter(receipts))).open('ab') as f: f.write(b'uncommitted-tail')
    session = dict(formatVersion=1, migrationID=migration, deviceID=device,
        chunksByPath=chunks, sealed=False, verifiedResources=receipts)
    (package.parent / 'session.json').write_text(json.dumps(session))
    (root / 'fixture.json').write_text(json.dumps(dict(migrationID=migration, deviceID=device,
        files=len(chunks), bytes=total_bytes, receipts=count, archive=archive)))

def run(binary, root, report, limit_mib=512, timeout=180):
    assert (root / 'SYNTHETIC-ONLY').is_file()
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    # Never inherit credentials or the Xcode debugging environment.
    env = {k: os.environ[k] for k in ('HOME', 'TMPDIR', 'PATH', 'LANG') if k in os.environ}
    started = time.monotonic(); peak = rss_peak = 0; samples = []; reason = None
    report.parent.mkdir(parents=True, exist_ok=True)
    with report.with_suffix('.log').open('w') as log:
        child = subprocess.Popen([str(binary), str(root)], stdout=log, stderr=log, env=env, start_new_session=True)
        try:
            while child.poll() is None:
                usage = Usage()
                rc = lib.proc_pid_rusage(child.pid, 2, ctypes.byref(usage))
                elapsed = time.monotonic() - started
                if rc == 0:
                    peak = max(peak, usage.footprint); rss_peak = max(rss_peak, usage.resident)
                    samples.append([round(elapsed, 3), usage.footprint, usage.resident])
                    if max(usage.footprint, usage.resident) > limit_mib * 1024**2: reason = 'memory-limit'
                elif child.poll() is None: reason = 'monitor-unavailable'
                if elapsed > timeout: reason = 'timeout'
                if reason:
                    os.killpg(child.pid, signal.SIGKILL); break
                time.sleep(.01)
            code = child.wait(timeout=5)
        finally:
            if child.poll() is None: os.killpg(child.pid, signal.SIGKILL); child.wait()
    result = dict(exit_code=code, stop_reason=reason, seconds=time.monotonic()-started,
        peak_footprint_bytes=peak, peak_rss_bytes=rss_peak, limit_mib=limit_mib, samples=samples)
    report.write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != 'samples'}), flush=True)
    return code == 0 and reason is None

if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('binary', type=pathlib.Path); p.add_argument('root', type=pathlib.Path)
    p.add_argument('report', type=pathlib.Path); p.add_argument('--create', type=int); p.add_argument('--chunks-per-file', type=int, default=2); p.add_argument('--archive', action='store_true')
    a=p.parse_args()
    if a.root.is_symlink() or str(a.root.resolve()).startswith('/Volumes/HDD2'):
        p.error('synthetic root must not use protected HDD2 or a symlink')
    if a.create is not None:
        if not 1 <= a.create <= 4096: p.error('file count must be 1...4096')
        if not 1 <= a.chunks_per_file <= 1024 or a.create * a.chunks_per_file > 16384: p.error('synthetic dataset capped at 64 GiB')
        fixture(a.root, a.create, a.chunks_per_file, a.archive)
    raise SystemExit(0 if run(a.binary, a.root, a.report) else 1)

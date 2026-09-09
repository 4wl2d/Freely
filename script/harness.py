#!/usr/bin/env python3
"""Low-priority Freely checks. No visible UI or capture permissions in the default mode."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / '.cache' / 'harness'
CURRENT = STATE / 'current.json'


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def current():
    try:
        return json.loads(CURRENT.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def process_snapshot():
    result = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat=,lstart='], text=True).splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            result[int(parts[0])] = dict(parent=int(parts[1]), state=parts[2], started=parts[3])
    return result


def stop_owned_tree(process):
    # SwiftPM helpers can create their own process groups. Track parentage and start
    # identity, so cancellation includes those helpers without selecting apps by name.
    snapshot = process_snapshot()
    owned = {}
    pending = [process.pid]
    while pending:
        pid = pending.pop()
        if pid in owned or pid not in snapshot: continue
        owned[pid] = snapshot[pid]
        pending.extend(child for child, info in snapshot.items() if info['parent'] == pid)
    for pid in reversed(list(owned)):
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    deadline = time.monotonic() + 5
    remaining = list(owned)
    while remaining and time.monotonic() < deadline:
        process.poll()  # Reap the direct child as soon as it exits.
        live = process_snapshot()
        remaining = [pid for pid, info in owned.items() if pid in live and live[pid]['started'] == info['started'] and not live[pid]['state'].startswith('Z')]
        if remaining: time.sleep(.05)
    for pid in remaining:
        # Check identity again immediately before escalation.
        live = process_snapshot().get(pid)
        if live and live['started'] == owned[pid]['started']:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
    process.wait(timeout=5)
    return list(owned)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', default='start', choices=['start', 'run', 'status', 'stop', 'visual'])
    parser.add_argument('--release', action='store_true')
    parser.add_argument('--stt-seconds', type=int, help='Optional 10–60 second local STT + synthetic video smoke check')
    parser.add_argument('--run-id', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.stt_seconds is not None and not 10 <= args.stt_seconds <= 60:
        parser.error('--stt-seconds must be between 10 and 60; long soaks are not part of this harness')
    STATE.mkdir(parents=True, exist_ok=True)
    if args.command in ['status', 'stop']:
        state = current()
        if not state:
            print('No harness run yet.'); return 0
        if args.command == 'stop' and state['status'] == 'running':
            directory = Path(state['directory']).resolve()
            if directory.parent != STATE.resolve():
                raise SystemExit('Invalid harness directory; refusing to address another process.')
            (directory / 'stop').touch()
            print('Stop requested. Only this harness and its child processes will be stopped.')
        else:
            print(json.dumps(state, indent=2))
        return 0

    token = args.run_id or datetime.datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8]
    if not token or any(c not in '0123456789abcdef-' for c in token):
        parser.error('Invalid run ID')
    directory = STATE / token
    directory.mkdir(exist_ok=True)
    if args.command == 'start':
        command = [sys.executable, str(Path(__file__).resolve()), 'run', '--run-id', token]
        if args.release: command.append('--release')
        if args.stt_seconds is not None: command += ['--stt-seconds', str(args.stt_seconds)]
        with (directory / 'runner.log').open('wb') as log:
            worker = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(30):
            state = current()
            if state and state.get('id') == token:
                print(f"Started in background. Status: {Path(__file__).resolve()} status\nLogs: {directory}"); return 0
            if worker.poll() is not None:
                print((directory / 'runner.log').read_text()); return worker.returncode
            time.sleep(0.1)
        print(f'Starting. Logs: {directory}'); return 0

    with (STATE / 'runner.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('A harness is already running. Use status or stop.'); return 2
        env = {key: value for key, value in os.environ.items() if not key.startswith('FREELY_')}
        if 'DEVELOPER_DIR' not in env and Path('/Applications/Xcode.app/Contents/Developer').exists():
            env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
        config = 'release' if args.release else 'debug'
        state = dict(id=token, status='running', mode='visual' if args.command == 'visual' else 'headless',
                     configuration=config, directory=str(directory), runnerPID=os.getpid(), phase='starting',
                     startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), results=[])
        cancelled = False
        def cancel(_signal, _frame):
            nonlocal cancelled
            cancelled = True
        signal.signal(signal.SIGINT, cancel)
        signal.signal(signal.SIGTERM, cancel)
        def persist():
            write_json(directory / 'result.json', state)
            write_json(CURRENT, state)
        def stopped():
            return cancelled or (directory / 'stop').exists()
        persist()
        phases = [
            ('core', ['swift', 'test', '--package-path', 'Packages/FreelyCore', '-c', config, '-j', '2'], 90, {}),
            ('build', ['swift', 'build', '--build-tests', '-c', config, '--arch', 'arm64', '-j', '2', '-Xswiftc', '-enable-testing'], 180, {})]
        test = ['swift', 'test', '--skip-build', '--arch', 'arm64', '--no-parallel', '-c', config]
        if args.command == 'visual':
            # An explicit manual check; the production test uses a small closable preview.
            phases.append(('visual', test + ['--filter', 'PresentationRuntimeTests'], 90, {'FREELY_PRESENTATION_TEST': '1'}))
        else:
            phases.append(('regression', test, 90, {}))
        if args.stt_seconds is not None:
            (ROOT / "Benchmarks/results/local").mkdir(parents=True, exist_ok=True)
            phases.append(('stt', test + ['--filter', 'IntegratedSoakTests.realTimeDualSourceLocalProcessing'],
                args.stt_seconds + 90, {'FREELY_SOAK': '1', 'FREELY_SOAK_SECONDS': str(args.stt_seconds),
                    'FREELY_SOAK_UI': '1', 'FREELY_SOAK_PRESENTATION': '1',
                    'FREELY_SOAK_CORPUS': str(ROOT / '.cache/redesign-soak-corpus'),
                    'FREELY_SOAK_RESULT_NAME': f'local/harness-{token}.json'}))
        exit_code = 0
        for name, command, timeout, flags in phases:
            if stopped(): state['status'] = 'cancelled'; exit_code = 130; break
            state['phase'] = name; state['log'] = str(directory / f'{name}.log'); persist()
            print(f'{name}: running at reduced priority; log {state["log"]}', flush=True)
            with Path(state['log']).open('wb') as log:
                process = subprocess.Popen(['/usr/bin/nice', '-n', '10', *command], cwd=ROOT,
                    env={**env, **flags}, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                state['childPID'] = process.pid; persist()
                started = time.monotonic()
                timed_out = False
                while process.poll() is None:
                    timed_out = time.monotonic() - started > timeout
                    if stopped() or timed_out:
                        state['stoppedPIDs'] = stop_owned_tree(process)
                        break
                    time.sleep(0.1)
                state.pop('childPID', None)
                state['results'].append(dict(phase=name, exitCode=process.returncode, seconds=round(time.monotonic() - started, 3), log=state['log']))
            if stopped(): state['status'] = 'cancelled'; exit_code = 130; break
            if timed_out: state['status'] = 'timed out'; exit_code = 124; break
            if process.returncode:
                state['status'] = 'failed'; exit_code = process.returncode; break
        else:
            state['status'] = 'passed'
        state['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        state['phase'] = 'finished'; state.pop('childPID', None); persist()
        print(f'{state["status"]}: {directory / "result.json"}', flush=True)
        return exit_code


if __name__ == '__main__':
    raise SystemExit(main())

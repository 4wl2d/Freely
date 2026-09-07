#!/usr/bin/env python3
"""Run native tests serially and retain diagnostics if the runner stalls."""
import os
from pathlib import Path
import signal
import subprocess
import sys

configuration = sys.argv[1] if len(sys.argv) > 1 else "debug"
if configuration not in {"debug", "release"}:
    raise SystemExit("Expected debug or release")
logs = Path(".cache/ci-tests") / configuration
logs.mkdir(parents=True, exist_ok=True)
command = ["swift", "test", "--skip-build", "--no-parallel", "-c", configuration, "--arch", "arm64", *sys.argv[2:]]
with (logs / "tests.log").open("wb") as output:
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        result = process.wait(timeout=120)
    except subprocess.TimeoutExpired:
        result = 124
        pending, observed = [process.pid], []
        while pending:
            pid = pending.pop()
            if pid in observed:
                continue
            observed.append(pid)
            children = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
            pending.extend(int(value) for value in children.stdout.split() if value.isdecimal())
        for pid in observed:
            try:
                subprocess.run(["/usr/bin/sample", str(pid), "2", "1", "-file", str(logs / f"process-{pid}.sample.txt")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            except (OSError, subprocess.TimeoutExpired) as error:
                (logs / f"process-{pid}.sample-error.txt").write_text(type(error).__name__ + "\n")
        print("Native test execution exceeded 120 seconds; process samples were saved.", flush=True)
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
sys.stdout.write((logs / "tests.log").read_text(errors="replace"))
raise SystemExit(result)

#!/usr/bin/env python3
"""Wine's own conformance tests for ntdll, kernel32 and kernelbase on this fork's wine.app (plan R2, N2 review item).

The test executables come from a tests-only configure of the same patched Wine tree
(build/wine-arm64-src/wine-tests-build, --enable-archs=aarch64,x86_64; see aoe2/results/n2.md). Lanes:
  arm64  the aarch64-windows tests, native
  x64    the x86_64-windows tests under FEX (libarm64ecfex.dll registered as the amd64 emulator)
Each test unit (`<module>_test.exe <unit>`) runs alone with a deadline. Its result is Wine's summary line
"<unit>: N tests executed (T marked as todo, F failures), S skipped." and its exit status; a unit without one crashed or
timed out. This is a measurement, not a gate: Wine has failures on macOS of its own. The finding is the comparison:
units that fail under FEX but pass natively point at FEX or the ARM64EC boundary.

Usage: winetest.py --lane arm64|x64 [--modules ntdll,kernel32,kernelbase] [--timeout 180]
Evidence: $AOE2_WORK_ROOT/n2/winetest-<lane>-<UTC stamp>/ (results.json, one log per unit).
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

REPO = Path(__file__).resolve().parent.parent.parent
WORK = Path(os.environ.get("AOE2_WORK_ROOT", Path.home() / "aoe2-poc-work"))
TESTS_BUILD = Path(os.environ.get("AOE2_WINETEST_BUILD", REPO / "build/wine-arm64-src/wine-tests-build"))
APP = Path(os.environ.get("AOE2_WINE_APP", REPO / "build/wine-arm64/wine.app"))
LOADER, SERVER = APP / "Contents/MacOS/wine", APP / "Contents/Resources/bin/wineserver"
ARCH = {"arm64": "aarch64-windows", "x64": "x86_64-windows"}
SUMMARY = re.compile(r"^(?:[0-9a-f]+:)?(\S+): (\d+) tests? executed \((\d+) marked as todo, (?:\d+ as flaky, )?(\d+) failures?\), "
                     r"(\d+) skipped\.")

parser = argparse.ArgumentParser()
parser.add_argument("--lane", choices=list(ARCH), required=True)
parser.add_argument("--modules", default="ntdll,kernel32,kernelbase")
parser.add_argument("--timeout", type=int, default=180)
ARGS = parser.parse_args()
STAMP = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
RUN = WORK / "n2" / f"winetest-{ARGS.lane}-{STAMP}"
PREFIX = RUN / "prefix"
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("WINE", "DYLD_", "FEX_"))}
ENV.update(WINEPREFIX=str(PREFIX), WINEMSYNC="1", WINEDEBUG="-all", WINETEST_PLATFORM="wine",
           WINETEST_INTERACTIVE="0", WINETEST_REPORT_SUCCESS="0", WINETEST_COLOR="0",
           WINEDLLOVERRIDES="winedbg.exe=d;mscoree,mshtml=")


def run(args, timeout, cwd=None):
    proc = subprocess.Popen([str(a) for a in args], env=ENV, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
        return proc.returncode, out.decode(errors="replace"), False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        subprocess.run([str(SERVER), "-k"], env=ENV, capture_output=True, timeout=30)
        try:
            out, _ = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired as exc:
            out = exc.output or b""
        return proc.returncode, (out or b"").decode(errors="replace"), True


RUN.mkdir(parents=True)
code, out, expired = run([LOADER, "wineboot", "-i"], 300)
(RUN / "wineboot.log").write_text(out)
assert code == 0 and not expired, f"wineboot -i failed: {code} {expired}"
if ARGS.lane == "x64":
    code, out, expired = run([LOADER, "reg", "add", r"HKLM\Software\Microsoft\Wow64\amd64", "/ve", "/d",
                              "libarm64ecfex.dll", "/f"], 60)
    assert code == 0 and not expired, out
report = dict(utc=STAMP, lane=ARGS.lane, wine_app=str(APP),
              wine_app_source=(APP / "Contents/Resources/licenses/SOURCE").read_text(), modules={})
for module in ARGS.modules.split(","):
    exe = TESTS_BUILD / f"dlls/{module}/tests/{ARCH[ARGS.lane]}/{module}_test.exe"
    code, out, expired = run([LOADER, exe, "--list"], 120)
    units = [l.strip() for l in out.replace("\r", "").splitlines() if l.startswith("    ")]
    print(f"=== {ARGS.lane} {module}: {len(units)} units", flush=True)
    rows = []
    for unit in units:
        started = time.monotonic()
        workdir = RUN / module / unit
        workdir.mkdir(parents=True)
        code, out, expired = run([LOADER, exe, unit], ARGS.timeout, cwd=workdir)
        (workdir / "output.log").write_text(out)
        summary = None
        for line in out.replace("\r", "").splitlines():
            m = SUMMARY.match(line)
            if m and m.group(1) == unit:
                summary = dict(executed=int(m.group(2)), todo=int(m.group(3)), failures=int(m.group(4)),
                               skipped=int(m.group(5)))
        status = ("timeout" if expired else "crash" if summary is None
                  else "pass" if summary["failures"] == 0 and code == 0 else "fail")
        row = dict(unit=unit, status=status, exit_code=code, seconds=round(time.monotonic() - started, 1),
                   **(summary or {}))
        rows.append(row)
        print(f"{status:8} {module}:{unit} {summary or ''} exit={code}", flush=True)
    report["modules"][module] = rows
    run([SERVER, "-k"], 30)
(RUN / "results.json").write_text(json.dumps(report, indent=2) + "\n")
for module, rows in report["modules"].items():
    counts = {s: sum(r["status"] == s for r in rows) for s in ("pass", "fail", "crash", "timeout")}
    print(f"=== {ARGS.lane} {module}: {counts}, {sum(r.get('failures', 0) for r in rows)} failed checks", flush=True)
print("Evidence:", RUN, flush=True)

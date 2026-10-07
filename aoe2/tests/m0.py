#!/usr/bin/env python3
"""M0 console suite on this fork's wine.app (plan R2, N2), ported from Aoe2MacSteamNoRosetta scripts/test-m0.py.

Two lanes, each with its own prefixes and the same cases:
  arm64  plain ARM64 PE (machine 0xAA64), native
  x64    x86-64 PE (machine 0x8664) under FEX (libarm64ecfex.dll registered as the amd64 emulator, as check.sh does)
Per lane: HELLO, MEM, SHARED, THREAD, CALLBACK, SEH, IO, SEH-UNHANDLED, 20 repeats, FRESH (a second prefix),
HOST-NATIVE and SERVER-CLEANUP for both prefixes: 32 checks. --exec-memory adds the 9 executable-memory cases: 41.

HOST-NATIVE differs from the companion's, which read diagnostics compiled into its own Wine 11.4: here it requires
Wine's +virtual trace to say `host page size: 4k` for every process of a run, the loader to be a thin arm64 Mach-O,
and the live Windows process (runtime.exe wait) to lack the kernel's P_TRANSLATED flag. MacNeutron's check.sh x18 step
covers the companion's custom-x18 marker at the unix boundary.

Usage: m0.py [--exec-memory] [--lane arm64|x64|both]   (default both)
Inputs: AOE2_WINE_APP (default build/wine-arm64/wine.app), cloned into the run directory; the pinned llvm-mingw
(dxmt/toolchain.sh). Evidence: $AOE2_WORK_ROOT/n2/m0-<UTC stamp>/ (default ~/aoe2-poc-work), results.json.
Exit 0 only if every check of every lane passes.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

TESTS = Path(__file__).resolve().parent
REPO = TESTS.parent.parent
WORK = Path(os.environ.get("AOE2_WORK_ROOT", Path.home() / "aoe2-poc-work"))
STAMP = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
RUN = WORK / "n2" / ("m0-" + STAMP)
SOURCE_APP = Path(os.environ.get("AOE2_WINE_APP", REPO / "build/wine-arm64/wine.app"))
APP = RUN / "wine app" / "wine.app"   # a path with a space, as the launcher installs it
LOADER = APP / "Contents/MacOS/wine"
SERVER = APP / "Contents/Resources/bin/wineserver"
TOOLCHAIN = Path(subprocess.check_output(["sh", str(REPO / "dxmt/toolchain.sh")], text=True).strip())
READOBJ = TOOLCHAIN / "llvm-readobj"
FLAGS = ["-O1", "-g", "-Wall", "-Wextra", "-Werror", "-fms-extensions", "-Xclang", "-fasync-exceptions"]
LANES = {"arm64": ("A64", "aarch64-w64-mingw32-clang", "IMAGE_FILE_MACHINE_ARM64 (0xAA64)"),
         "x64": ("X64", "x86_64-w64-mingw32-clang", "IMAGE_FILE_MACHINE_AMD64 (0x8664)")}
EXEC_CASES = ["exec-heap", "exec-rwx", "exec-transition", "exec-commit", "exec-protect", "exec-alloc-state",
              "exec-rollback", "exec-protect-span", "exec-heap-leak"]
P_TRANSLATED = 0x20000

parser = argparse.ArgumentParser()
parser.add_argument("--exec-memory", action="store_true")
parser.add_argument("--lane", choices=["arm64", "x64", "both"], default="both")
ARGS = parser.parse_args()

BASE_ENV = {k: v for k, v in os.environ.items()
            if not k.startswith(("WINE", "DYLD_", "FEX_")) and k != "STEAM_COMPAT_DATA_PATH"}
BASE_ENV.update(WINEDEBUG="-all", WINEMSYNC="1")   # msync on, as the launcher and check.sh run it


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def env_for(prefix, **extra):
    env = dict(BASE_ENV, WINEPREFIX=str(prefix))
    env.update(extra)
    return env


def stop_prefix_processes(prefix):
    """Spawned Wine processes can leave our process group; select them only by this run's exact WINEPREFIX."""
    if not str(prefix).startswith(str(RUN) + os.sep):
        return
    listing = subprocess.check_output(["ps", "eww", "-axo", "pid=,command="], text=True)
    for row in listing.splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and f"WINEPREFIX={prefix} " in fields[1] + " " and int(fields[0]) != os.getpid():
            try:
                os.kill(int(fields[0]), signal.SIGKILL)
            except ProcessLookupError:
                pass


def command(args, env, cwd=None, timeout=30):
    proc = subprocess.Popen([str(a) for a in args], env=env, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace"), False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        try:
            subprocess.run([str(SERVER), "-k"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=10)
        except subprocess.TimeoutExpired:
            pass
        stop_prefix_processes(env["WINEPREFIX"])
        try:
            out, err = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired as exc:
            out, err = exc.output or b"", exc.stderr or b""
        return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace"), True


class Lane:
    def __init__(self, name):
        self.name = name
        self.tag, compiler, self.machine = LANES[name]
        self.compiler = TOOLCHAIN / compiler
        self.dir = RUN / name
        self.prefix = self.dir / "prefix"
        self.fresh = self.dir / "fresh-prefix"
        self.env = env_for(self.prefix)
        self.results = []

    def record(self, test_id, passed, **fields):
        self.results.append(dict(test_id=test_id, passed=passed, **fields))
        print(("PASS " if passed else "FAIL ") + test_id + (f" (exit {fields['exit_code']})"
              if "exit_code" in fields else ""), flush=True)
        return passed

    def build(self):
        self.dir.mkdir(parents=True)
        for stem, src in [("hello", TESTS / "m0/a64_hello.c"), ("runtime", TESTS / "m0/runtime.c")]:
            exe = self.dir / (stem + ".exe")
            subprocess.run([str(self.compiler), *FLAGS, str(src), "-o", str(exe)], check=True)
            headers = subprocess.check_output([str(READOBJ), "--file-headers", "--coff-imports", str(exe)], text=True)
            (self.dir / (stem + "-headers.txt")).write_text(headers)
            if self.machine not in headers:
                raise RuntimeError(f"{exe} is not {self.machine}")
        self.hello, self.runtime = self.dir / "hello.exe", self.dir / "runtime.exe"

    def prepare_prefix(self, prefix):
        env = env_for(prefix, WINEDLLOVERRIDES="mscoree,mshtml=")
        code, out, err, expired = command([LOADER, "wineboot", "-i"], env, timeout=180)
        (self.dir / (prefix.name + "-wineboot.log")).write_text(f"exit={code} timeout={expired}\n{out}{err}")
        if code or expired:
            raise RuntimeError(f"wineboot -i in {prefix} failed (exit {code}, timeout {expired})")
        if self.name == "x64":
            code, out, err, expired = command([LOADER, "reg", "add", r"HKLM\Software\Microsoft\Wow64\amd64", "/ve",
                                               "/d", "libarm64ecfex.dll", "/f"], env)
            if code or expired:
                raise RuntimeError(f"registering FEX in {prefix} failed: {out}{err}")

    def case(self, test_id, binary, args, expected_code=0, expected_line=None, timeout=30, env=None,
             expected_fault=None):
        env = env or self.env
        cwd = self.dir / test_id
        cwd.mkdir()
        started = time.monotonic()
        cmd = [LOADER, binary, *args]
        code, out, err, expired = command(cmd, env, cwd=cwd, timeout=timeout)
        (cwd / "stdout.log").write_text(out)
        (cwd / "stderr.log").write_text(err)
        passed = (not expired and code == expected_code
                  and (expected_line is None or expected_line in out.replace("\r", "").splitlines())
                  and ((expected_fault in err) if expected_fault else "Unhandled" not in err))
        if not passed:
            print(err[-2000:], flush=True)
        return self.record(test_id, passed, command=list(map(str, cmd)), exit_code=code, timeout=expired,
                           expected_exit=expected_code, expected_line=expected_line, expected_fault=expected_fault,
                           seconds=round(time.monotonic() - started, 3))

    def host_native(self):
        """4K pages by Wine's own trace, a thin arm64 loader, and a live Windows process that isn't translated."""
        test_id = self.tag + "-HOST-NATIVE"
        why = []
        archs = subprocess.check_output(["lipo", "-archs", str(LOADER)], text=True).strip()
        if archs != "arm64":
            why.append(f"loader archs {archs}")
        code, out, err, expired = command([LOADER, self.hello], env_for(self.prefix, WINEDEBUG="+virtual"),
                                          cwd=self.dir, timeout=60)
        (self.dir / "host-native-virtual.log").write_text(err)
        pages = [l.split("host page size:")[1].strip() for l in err.replace("\r", "").splitlines()
                 if "host page size:" in l]
        if code != 23 or expired:
            why.append(f"hello exit {code} timeout {expired}")
        if not pages or any(p != "4k" for p in pages):
            why.append(f"host page sizes {pages}")
        # The wait case: its host process, while it runs.
        proc = subprocess.Popen([str(LOADER), str(self.runtime), "wait"], env=self.env, cwd=self.dir,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        line, flags, comm = b"", None, None
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and b"READY" not in line:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
        if b"M0 wait READY" in line:
            row = subprocess.run(["ps", "-o", "flags=,comm=", "-p", str(proc.pid)], capture_output=True,
                                 text=True).stdout.strip()
            if row:
                flags, comm = row.split(None, 1)
                if int(flags, 16) & P_TRANSLATED:
                    why.append(f"pid {proc.pid} has P_TRANSLATED (flags {flags})")
            else:
                why.append(f"pid {proc.pid} not found while waiting")
        else:
            why.append("wait never printed READY")
        os.kill(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=20)
            ended = proc.returncode
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
            ended = "timeout"
            why.append("wait survived SIGTERM for 20 s")
        if b"FAIL wait was not interrupted" in out:
            why.append("wait ran to its end")
        return self.record(test_id, not why, loader_archs=archs, page_size_lines=len(pages), pid_flags=flags,
                           pid_comm=comm, wait_exit_after_sigterm=ended, problems=why)

    def cleanup(self):
        for prefix in [self.prefix, self.fresh]:
            if not prefix.exists():
                continue
            env = env_for(prefix)
            code, out, err, expired = command([SERVER, "-k"], env)
            # Wine returns 1 when no server holds the prefix's lock; -w below confirms termination either way.
            kill_ok = not expired and code in (0, 1) and not err
            wcode, wout, werr, wexpired = command([SERVER, "-w"], env)
            (self.dir / (prefix.name + "-cleanup.log")).write_text(
                f"kill_exit={code} kill_timeout={expired}\n{out}{err}wait_exit={wcode} wait_timeout={wexpired}\n"
                f"{wout}{werr}")
            stop_prefix_processes(prefix)
            self.record(f"{self.tag}-SERVER-CLEANUP-{prefix.name}", kill_ok and not wexpired and wcode == 0,
                        kill_exit=code, wait_exit=wcode, timeout=expired or wexpired)

    def run(self):
        t = self.tag
        try:
            self.build()
            self.prepare_prefix(self.prefix)
            if self.case(t + "-HELLO", self.hello, [], 23, "A64-HELLO OK", 120):
                for name, tid in [("memory", "MEM"), ("shared", "SHARED"), ("threads", "THREAD"),
                                  ("callback", "CALLBACK"), ("exceptions", "SEH"), ("io", "IO")]:
                    self.case(f"{t}-{tid}", self.runtime, [name], expected_line=f"M0 {name} PASS")
                no_debugger = dict(self.env, WINEDLLOVERRIDES="winedbg.exe=d")
                if ARGS.exec_memory:
                    for name in EXEC_CASES:
                        self.case(f"{t}-{name.upper()}", self.runtime, [name], expected_line=f"M0 {name} PASS",
                                  env=no_debugger)
                # The negative fixture has to end, not start an interactive debugger.
                self.case(t + "-SEH-UNHANDLED", self.runtime, ["unhandled"], 5, env=no_debugger,
                          expected_fault="Unhandled page fault on write access to 0000000000001234")
                for i in range(20):
                    if not self.case(f"{t}-REPEAT-{i + 1:02d}", self.hello, [], 23, "A64-HELLO OK"):
                        break
                self.prepare_prefix(self.fresh)
                self.case(t + "-FRESH", self.hello, [], 23, "A64-HELLO OK", 120, env_for(self.fresh))
                self.host_native()
        except Exception as exc:   # the harness's own failure is a failed check, never a skipped one
            self.record(t + "-HARNESS", False, error=str(exc))
        finally:
            self.cleanup()
        return self.results


RUN.mkdir(parents=True)
APP.parent.mkdir()
subprocess.run(["cp", "-cR", str(SOURCE_APP), str(APP)], check=True)
report = dict(utc=STAMP, host=subprocess.check_output(["sw_vers"], text=True),
              model=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
              wine_app=str(SOURCE_APP), wine_app_source=(APP / "Contents/Resources/licenses/SOURCE").read_text(),
              artifacts={}, compiler=subprocess.check_output([str(TOOLCHAIN / "clang"), "--version"], text=True),
              probe_flags=FLAGS, environment={k: BASE_ENV[k] for k in ["WINEDEBUG", "WINEMSYNC"]},
              exec_memory=ARGS.exec_memory, lanes={})
for name in (["arm64", "x64"] if ARGS.lane == "both" else [ARGS.lane]):
    print(f"=== lane {name}", flush=True)
    results = Lane(name).run()
    expected = 41 if ARGS.exec_memory else 32
    report["lanes"][name] = dict(expected_checks=expected, checks=len(results),
                                 passed=sum(r["passed"] for r in results), results=results)
    print(f"=== lane {name}: {sum(r['passed'] for r in results)}/{expected} "
          f"({len(results)} recorded)", flush=True)
for p in [LOADER, SERVER, APP / "Contents/Resources/lib/wine/aarch64-unix/ntdll.so",
          *RUN.glob("*/hello.exe"), *RUN.glob("*/runtime.exe")]:
    report["artifacts"][str(p.relative_to(RUN))] = digest(p)
(RUN / "results.json").write_text(json.dumps(report, indent=2) + "\n")
shutil.rmtree(APP.parent, ignore_errors=True)   # 1.3 GB clone; its hashes are in results.json
print("Evidence:", RUN, flush=True)
ok = all(l["checks"] == l["expected_checks"] and l["passed"] == l["checks"] for l in report["lanes"].values())
sys.exit(0 if ok else 1)

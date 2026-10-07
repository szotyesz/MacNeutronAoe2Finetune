#!/usr/bin/env python3
"""Replays Steam's AoE2DE launch through MacNeutron's tool, outside Steam, so a run can be repeated with changed
variables (WINEDEBUG, FEX_*, another tool folder) (plan R2, N3).

The environment comes from the launch MacNeutron logged for Steam (`~/Library/Logs/MacNeutron/steam-813780.log`, written
when AoE2DE's per-game log is on). It is saved once, privately, because it names the Steam account:
  replay-launch.py --save-env            after one launch from Steam: writes $AOE2_WORK_ROOT/n3/steam-env.txt (0600)
  replay-launch.py <out dir> <seconds> [KEY=VALUE ...]
The replay leaves out the login names (SteamUser, SteamAppUser, MACNEUTRON_STEAM_ACCOUNT: the launcher derives the
account itself), this session's own variables and the logged WINEDEBUG. KEY=VALUE adds or replaces a variable; KEY=
removes it. GAME_ARGS=SKIPINTRO passes game arguments, as Steam does. STEAM_COMPAT_TOOL_PATHS=<tool folder> runs another
runtime (`.build/release/macneutron install --tool-dir <dir> --wine-app <wine.app> --steam-exe build/bridge/arm64/steam.exe`).
With MACNEUTRON_LOG=1 (in the saved environment) Wine's output goes to MacNeutron's game log, not to <out dir>.
Output: <out dir>/env.txt, <out dir>/wine.log, <out dir>/exit. Prints the exit status (None: still running at the end).
"""
import os, subprocess, sys, time
from pathlib import Path

WORK = Path(os.environ.get("AOE2_WORK_ROOT", Path.home() / "aoe2-poc-work"))
ENV_FILE = Path(os.environ.get("AOE2_STEAM_ENV", WORK / "n3/steam-env.txt"))
GAME_LOG = Path.home() / "Library/Logs/MacNeutron/steam-813780.log"

if sys.argv[1:] == ["--save-env"]:
    lines = GAME_LOG.read_text(errors="replace").splitlines()
    starts = [i for i, l in enumerate(lines) if l.startswith("=== ") and "AoE2DE_s.exe" in l]
    if not starts:
        sys.exit(f"no AoE2DE launch in {GAME_LOG}: turn the game's log on in MacNeutron and launch it from Steam once")
    block = [lines[starts[-1]]]
    for l in lines[starts[-1] + 1:]:
        if "=" not in l or l.startswith(("0", "msync", "wine")): break
        block.append(l)
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    ENV_FILE.write_text("\n".join(block) + "\n"); ENV_FILE.chmod(0o600)
    sys.exit(print(len(block) - 1, "variables saved to", ENV_FILE))

out, secs, extra = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
out.mkdir(parents=True, exist_ok=True)
lines = ENV_FILE.read_text(errors="replace").splitlines()
start = max(i for i, l in enumerate(lines) if l.startswith("=== ") and "AoE2DE_s.exe" in l)
skip = ("AI_AGENT", "CLAUDE", "COREPACK", "GIT_EDITOR", "SSH_AUTH_SOCK", "SteamUser", "SteamAppUser",
        "MACNEUTRON_STEAM_ACCOUNT", "WINEDEBUG", "OLDPWD", "PWD", "SHLVL", "_")
env = {}
for l in lines[start + 1:]:
    if "=" not in l or l.startswith(("0", "msync", "wine")): break
    k, v = l.split("=", 1)
    if not k.startswith(skip) and "<redacted>" not in v: env[k] = v
for kv in extra:
    k, v = kv.split("=", 1)
    if v: env[k] = v
    else: env.pop(k, None)
tool = Path(env["STEAM_COMPAT_TOOL_PATHS"].rstrip("/."))
exe = Path(env["STEAM_COMPAT_INSTALL_PATH"]) / "AoE2DE_s.exe"
(out / "env.txt").write_text("".join(f"{k}={v}\n" for k, v in sorted(env.items())))
with open(out / "wine.log", "wb") as f:
    game_args = env.pop("GAME_ARGS", "").split()  # what Steam passes after the exe, e.g. SKIPINTRO
    p = subprocess.Popen([str(tool / "bin/macneutron"), "launch", "waitforexitandrun", str(exe), *game_args], env=env,
                         cwd=str(exe.parent), stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    t0 = time.time()
    while p.poll() is None and time.time() - t0 < secs: time.sleep(1)
    status = p.poll()
(out / "exit").write_text(f"{status} after {int(time.time() - t0)} s\n")
print("exit", status, "after", int(time.time() - t0), "s")

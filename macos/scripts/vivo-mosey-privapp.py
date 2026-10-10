#!/usr/bin/env python3
"""Promote Mosey to a /product privileged app with two read-only OverlayFS mounts.

Nothing is written to /product (EROFS, dm-verity). The overlay upper/work
directories live on a private tmpfs, so a full reboot drops everything.
"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("vivo_cn_google", HERE / "vivo-cn-google.py")
cn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cn)
Adb, Error, check_device = cn.Adb, cn.Error, cn.check_device

PACKAGE = "com.google.android.mosey"
APKS = ["base.apk", "split_config.arm64_v8a.apk", "split_config.xxhdpi.apk", "split_config.en.apk"]
PERM_XML = "privapp-permissions-mosey-vivo.xml"
HIDDENAPI_XML = "mosey-hiddenapi-vivo.xml"
LOCAL_HELPER = HERE / "vivo-mosey-privapp-device.sh"
LOCAL_PAYLOAD = HERE.parent / "module-mosey-vivo" / "payload"
REMOTE_HELPER = "/data/local/tmp/vivo-mosey-privapp-device.sh"
REMOTE_INCOMING = "/data/local/tmp/vivo-mosey-privapp-incoming"
REMOTE_STATE = "/data/local/vivo-mosey-privapp"
KSUD = "/data/adb/ksud"
# Runtime (dangerous) permissions Mosey requests; an allowlist cannot grant these.
RUNTIME_PERMS = [
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.ACCESS_BACKGROUND_LOCATION",
    "android.permission.NEARBY_WIFI_DEVICES",
    "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_ADVERTISE",
]
CRASH_LOOP_LIMIT = 3


# --- pure helpers (unit tested) -------------------------------------------------

def payload_files(payload=LOCAL_PAYLOAD):
    rel = [f"priv-app/MoseyApp/{apk}" for apk in APKS] + [f"permissions/{PERM_XML}", f"permissions/{HIDDENAPI_XML}"]
    missing = [r for r in rel if not (Path(payload) / r).is_file()]
    if missing:
        raise Error(f"Payload incomplete under {payload}: {', '.join(missing)}")
    return rel


def checksum_list(payload=LOCAL_PAYLOAD):
    lines = []
    for rel in payload_files(payload):
        digest = hashlib.sha256((Path(payload) / rel).read_bytes()).hexdigest()
        lines.append(f"{digest}  {rel}")
    return "\n".join(lines) + "\n"


def hiddenapi_exempt(xml_bytes):
    root = ET.fromstring(xml_bytes)
    return any(n.tag == "hidden-api-whitelisted-app" and n.get("package") == PACKAGE for n in root)


def allowlisted_permissions(xml_bytes):
    root = ET.fromstring(xml_bytes)
    if root.tag != "permissions":
        raise Error(f"Unexpected allowlist root: {root.tag}")
    blocks = [n for n in root if n.tag == "privapp-permissions" and n.get("package") == PACKAGE]
    if len(blocks) != 1:
        raise Error("Allowlist must contain exactly one privapp-permissions block for Mosey.")
    return {n.get("name") for n in blocks[0] if n.tag == "permission" and n.get("name")}


def parse_protection_levels(text):
    """`pm list permissions -f` -> {permission: protectionLevel}."""
    levels, current = {}, None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("+ permission:"):
            current = line[len("+ permission:"):]
        elif current and line.startswith("protectionLevel:"):
            levels[current] = line[len("protectionLevel:"):]
    return levels


def parse_package_dump(text):
    """Active package block of `dumpsys package <pkg>` -> dict."""
    block = []
    in_packages = False
    for line in text.splitlines():
        if line.startswith("Packages:"):
            in_packages = True
            continue
        if in_packages and line and not line.startswith(" "):
            break
        if in_packages:
            block.append(line)
    if not any(f"Package [{PACKAGE}]" in line for line in block):
        raise Error(f"{PACKAGE} is not installed.")
    state = {"codePath": None, "hiddenApiPolicy": None, "pkgFlags": [], "privatePkgFlags": [],
             "requested": [], "install": {}, "runtime": {}}
    section = None
    for line in block:
        stripped = line.strip()
        if stripped.startswith("codePath="):
            state["codePath"] = stripped.split("=", 1)[1]
        elif stripped.startswith("hiddenApiEnforcementPolicy="):
            state["hiddenApiPolicy"] = stripped.split("=", 1)[1]
        elif stripped.startswith("pkgFlags=["):
            state["pkgFlags"] = stripped[len("pkgFlags=["):].rstrip("]").split()
        elif stripped.startswith("privatePkgFlags=["):
            state["privatePkgFlags"] = stripped[len("privatePkgFlags=["):].rstrip("]").split()
        elif stripped == "requested permissions:":
            section = "requested"
        elif stripped == "install permissions:":
            section = "install"
        elif stripped == "runtime permissions:":
            section = "runtime"
        elif stripped.endswith(":") and not stripped.startswith("android.permission"):
            section = None
        elif section == "requested" and stripped.startswith("android.permission."):
            state["requested"].append(stripped)
        elif section in {"install", "runtime"}:
            match = re.match(r"([\w.]+): granted=(true|false)", stripped)
            if match:
                state[section][match.group(1)] = match.group(2) == "true"
    return state


def missing_allowlist_entries(requested, levels, allowlist):
    """Privileged permissions Mosey requests that the allowlist does not cover.

    With ro.control_privapp_permissions=enforce, any such entry makes
    system_server throw at boot, so this must be empty before mounting.
    """
    privileged = {p for p in requested if "privileged" in levels.get(p, "").split("|")}
    return sorted(privileged - allowlist)


def unexpected_allowlist_entries(allowlist, levels):
    """Allowlist names that are not privileged permissions on this ROM (informational)."""
    return sorted(p for p in allowlist if "privileged" not in levels.get(p, "").split("|"))


# --- device access -------------------------------------------------------------

def helper(adb, *args):
    return adb.shell(shlex.join(["/system/bin/sh", REMOTE_HELPER, *args]), timeout=120).stdout.decode()


def inspect(adb):
    adb.run("push", str(LOCAL_HELPER), REMOTE_HELPER)
    out = helper(adb, "inspect")
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def package_state(adb):
    return parse_package_dump(adb.text(f"dumpsys package {PACKAGE}"))


def protection_levels(adb):
    return parse_protection_levels(adb.shell("pm list permissions -f", timeout=60).stdout.decode())


def validate_allowlist(adb, requested):
    allowlist = allowlisted_permissions((LOCAL_PAYLOAD / "permissions" / PERM_XML).read_bytes())
    levels = protection_levels(adb)
    missing = missing_allowlist_entries(requested, levels, allowlist)
    if missing:
        raise Error("Allowlist does not cover privileged permissions Mosey requests; with "
                    "ro.control_privapp_permissions=enforce this would crash system_server: " + ", ".join(missing))
    return {
        "privileged_allowlisted": sorted(p for p in allowlist if p in requested and "privileged" in levels.get(p, "").split("|")),
        "not_grantable_by_allowlist": unexpected_allowlist_entries(allowlist, levels),
    }


def install_payload(adb):
    sums = checksum_list()
    with tempfile.TemporaryDirectory(prefix="vivo-mosey-") as temp:
        local_sums = Path(temp) / "SHA256SUMS"
        local_sums.write_text(sums)
        adb.run("push", str(local_sums), f"{REMOTE_INCOMING}.sums")
    adb.shell(f"mkdir -p {REMOTE_STATE} && chmod 0700 {REMOTE_STATE} && chown 0:0 {REMOTE_STATE}")
    ok = adb.shell(
        f"cd {REMOTE_STATE}/payload 2>/dev/null && sha256sum -cs {REMOTE_INCOMING}.sums && "
        f"cmp -s {REMOTE_INCOMING}.sums {REMOTE_STATE}/SHA256SUMS",
        check=False).returncode == 0
    if ok:
        adb.shell(f"rm -f {REMOTE_INCOMING}.sums")
        return "payload already present"
    adb.shell(f"rm -rf {REMOTE_INCOMING}; mkdir -p {REMOTE_INCOMING}")
    for rel in payload_files():
        adb.run("push", str(LOCAL_PAYLOAD / rel), f"{REMOTE_INCOMING}/{rel}", timeout=300)
    adb.shell(
        f"rm -rf {REMOTE_STATE}/payload && cp -r {REMOTE_INCOMING} {REMOTE_STATE}/payload && "
        f"cp {REMOTE_INCOMING}.sums {REMOTE_STATE}/SHA256SUMS && chown -R 0:0 {REMOTE_STATE} && "
        f"chmod -R u=rwX,go= {REMOTE_STATE} && rm -rf {REMOTE_INCOMING} {REMOTE_INCOMING}.sums && "
        f"cd {REMOTE_STATE}/payload && sha256sum -cs ../SHA256SUMS")
    return "payload pushed"


def system_server_pid(adb):
    try:
        return adb.text("pidof system_server")
    except Error:
        return ""


def refresh_android(adb, verify, rollback):
    """ksud soft-reboot, then wait for `verify(adb)`; roll back on a crash loop."""
    if adb.shell(f"test -x {KSUD}", check=False).returncode:
        raise Error("ksud is unavailable; mounts are prepared but Android was not refreshed.")
    boot_before = adb.text("cat /proc/sys/kernel/random/boot_id")
    old_pid = system_server_pid(adb)
    adb.shell(f"{KSUD} soft-reboot")
    print("Refreshing Android with ksud soft-reboot; keeping the current kernel.", flush=True)
    seen, deadline = [], time.monotonic() + 180
    while time.monotonic() < deadline:
        time.sleep(3)
        pid = system_server_pid(adb)
        if pid and pid != old_pid and pid not in seen:
            seen.append(pid)
        if len(seen) >= CRASH_LOOP_LIMIT:
            print(f"system_server restarted {len(seen)} times; rolling back.", file=sys.stderr, flush=True)
            rollback(adb)
            adb.shell(f"{KSUD} soft-reboot", check=False)
            raise Error("system_server crash loop detected after refresh. Mounts were removed and Android "
                        "refreshed again. Check `logcat -b crash` / `logcat -d -s AndroidRuntime` for the cause.")
        try:
            ready = bool(pid) and pid != old_pid and adb.text("getprop sys.boot_completed") == "1" and verify(adb)
        except (subprocess.TimeoutExpired, Error):
            ready = False
        if ready:
            if adb.text("cat /proc/sys/kernel/random/boot_id") != boot_before:
                raise Error("Kernel boot ID changed unexpectedly; check the device before continuing.")
            if adb.text("id -u") != "0":
                raise Error("Root was lost after the Android refresh.")
            return
    raise Error("Android refresh verification timed out. Run status to inspect the current state.")


def promoted(adb):
    state = package_state(adb)
    return ("SYSTEM" in state["pkgFlags"] and "PRIVILEGED" in state["privatePkgFlags"]
            and state["install"].get("android.permission.BLUETOOTH_PRIVILEGED") is True
            and state["hiddenApiPolicy"] == "0")


def demoted(adb):
    try:
        state = package_state(adb)
    except Error as exc:
        if "not installed" in str(exc):
            return True
        raise
    return "SYSTEM" not in state["pkgFlags"]


def grant_runtime(adb):
    results = {}
    for perm in RUNTIME_PERMS:
        rc = adb.shell(f"pm grant {PACKAGE} {perm}", check=False)
        results[perm] = "granted" if rc.returncode == 0 else (rc.stdout + rc.stderr).decode(errors="replace").strip()
    adb.shell(f"cmd package unstop --user 0 {PACKAGE}", check=False)
    return results


def summary(adb):
    state = package_state(adb)
    allowlist = allowlisted_permissions((LOCAL_PAYLOAD / "permissions" / PERM_XML).read_bytes())
    return {
        "codePath": state["codePath"],
        "system": "SYSTEM" in state["pkgFlags"],
        "privileged": "PRIVILEGED" in state["privatePkgFlags"],
        "hidden_api_exempt": state["hiddenApiPolicy"] == "0",
        "privileged_grants": {p: state["install"].get(p, False) for p in sorted(allowlist)},
        "runtime_grants": {p: state["runtime"].get(p, False) for p in RUNTIME_PERMS},
        "cn_google_services": cn.feature_value(adb),
    }


# --- commands ------------------------------------------------------------------

def run_cn(args):
    cmd = [sys.executable, str(HERE / "vivo-cn-google.py"), *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    if result.returncode:
        raise Error("vivo-cn-google.py failed: " + result.stderr.strip())


def status(adb):
    info = check_device(adb)
    print(json.dumps({**info, "mounts": inspect(adb), **summary(adb)}, indent=2))


def apply(adb, dry_run=False, no_restart=False, skip_cn=False):
    check_device(adb)
    mounts = inspect(adb)
    if "foreign" in (mounts["apps_mount"], mounts["permissions_mount"], mounts["tmpfs"]):
        raise Error("A foreign mount covers a target path; nothing was applied: " + json.dumps(mounts))
    print(install_payload(adb))
    if not hiddenapi_exempt((LOCAL_PAYLOAD / "permissions" / HIDDENAPI_XML).read_bytes()):
        raise Error(f"{HIDDENAPI_XML} does not exempt {PACKAGE} from hidden API checks.")
    checks = validate_allowlist(adb, package_state(adb)["requested"])
    print("Allowlist check:", json.dumps(checks))
    if dry_run:
        print(helper(adb, "selftest").strip())
        print("Dry run: overlay rehearsed on a scratch mountpoint only; product paths untouched, no restart.")
        return
    if not no_restart and adb.shell(f"test -x {KSUD}", check=False).returncode:
        raise Error("ksud is unavailable; refusing apply because the default Android refresh cannot run.")
    print(helper(adb, "apply").strip())
    if not skip_cn:
        run_cn(["--serial", adb.prefix[-1], "apply", "--no-restart"])
    if no_restart:
        print("Overlays are mounted. Android has not rescanned; run apply again without --no-restart to refresh.")
        return
    refresh_android(adb, verify=promoted, rollback=lambda a: helper(a, "restore"))
    print("Runtime grants:", json.dumps(grant_runtime(adb), indent=2))
    print(json.dumps(summary(adb), indent=2))


def restore(adb, no_restart=False):
    check_device(adb)
    mounts = inspect(adb)
    print(helper(adb, "restore").strip() or "No overlay from this script is active.")
    if no_restart:
        print("Original product content is visible; Android still holds the previous package scan.")
        return
    if mounts["apps_mount"] == "owned" or not demoted(adb):
        refresh_android(adb, verify=demoted, rollback=lambda a: None)
    print(json.dumps(summary(adb), indent=2))
    print("CN flag bind is left as is; use vivo-cn-google.py restore to remove it.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default=cn.SERIAL)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="Mount state, package flags and permission grants")
    ap = commands.add_parser("apply", help="Mount overlays, bind the CN flag, refresh Android, verify")
    ap.add_argument("--dry-run", action="store_true", help="Push payload and rehearse the overlay on a scratch path")
    ap.add_argument("--no-restart", action="store_true", help="Mount only; do not refresh Android")
    ap.add_argument("--skip-cn", action="store_true", help="Do not run vivo-cn-google.py apply --no-restart")
    rp = commands.add_parser("restore", help="Remove the overlays and refresh Android")
    rp.add_argument("--no-restart", action="store_true")
    args = parser.parse_args(argv)
    adb = Adb(args.serial)
    try:
        if args.command == "status":
            status(adb)
        elif args.command == "apply":
            apply(adb, dry_run=args.dry_run, no_restart=args.no_restart, skip_cn=args.skip_cn)
        else:
            restore(adb, no_restart=args.no_restart)
    except (Error, OSError, ET.ParseError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

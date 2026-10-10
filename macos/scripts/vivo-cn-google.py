#!/usr/bin/env python3
"""Manual Vivo CN feature override through one XML bind and a framework refresh."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

SERIAL = "10AG3T1KH6001KX"
TARGET = "/product/etc/sysconfig/cn_feature.xml"
REMOTE_HELPER = "/data/local/tmp/vivo-cn-google-device.sh"
REMOTE_INPUT = "/data/local/tmp/vivo-cn-google-input.xml"
FEATURE = "cn.google.services"
UPDATER = "com.google.android.feature.services_updater"
KSUD = "/data/adb/ksud"
LOCAL_HELPER = Path(__file__).with_name("vivo-cn-google-device.sh")
BUSYBOX = "/data/adb/ksu/bin/busybox"


class Error(RuntimeError):
    pass


class Adb:
    def __init__(self, serial=SERIAL):
        self.prefix = ["adb", "-s", serial]

    def run(self, *args, check=True, timeout=30):
        result = subprocess.run(
            [*self.prefix, *args], capture_output=True, timeout=timeout
        )
        if check and result.returncode:
            detail = (result.stderr + result.stdout).decode(errors="replace").strip()
            raise Error(detail or f"ADB returned {result.returncode}")
        return result

    def shell(self, command, check=True, timeout=30):
        return self.run("shell", command, check=check, timeout=timeout)

    def text(self, command, check=True):
        return self.shell(command, check=check).stdout.decode().strip()

    def helper(self, *args):
        command = shlex.join(["/system/bin/sh", REMOTE_HELPER, *args])
        return self.shell(command).stdout


def transform_xml(original):
    try:
        root = ET.fromstring(original)
    except ET.ParseError as exc:
        raise Error(f"Invalid ROM XML: {exc}") from exc
    if root.tag not in {"config", "permissions"}:
        raise Error(f"Unsupported XML root: {root.tag}")
    features = [node for node in root if node.tag == "feature" and node.get("name") == FEATURE]
    unavailable = [node for node in root if node.tag == "unavailable-feature" and node.get("name") == FEATURE]
    updater = [node for node in root if node.tag == "feature" and node.get("name") == UPDATER]
    if len(updater) != 1:
        raise Error("Expected exactly one services_updater feature; review the new ROM first.")
    if len(features) != 1 or unavailable:
        raise Error("Expected one CN feature and no existing CN override; review this XML first.")
    features[0].tag = "unavailable-feature"
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def feature_value(adb):
    result = adb.shell(f"cmd package has-feature {FEATURE}", check=False)
    value = result.stdout.decode().strip()
    # Android returns exit status 1 for a valid 'false' result.
    if value not in {"true", "false"}:
        raise Error("PackageManager unavailable: " + (result.stdout + result.stderr).decode(errors="replace").strip())
    return value == "true"


def check_device(adb):
    info = {
        "model": adb.text("getprop ro.product.model"),
        "sdk": adb.text("getprop ro.build.version.sdk"),
        "build": adb.text("getprop ro.build.display.id"),
        "uid": adb.text("id -u"),
    }
    if info["model"] != "V2547A" or info["sdk"] != "36":
        raise Error(f"Expected Vivo V2547A / API 36; got {info['model']} / API {info['sdk']}.")
    if info["uid"] != "0":
        raise Error("ADB shell is not root. Restore root through your own workflow, then rerun; this script does not acquire root.")
    return info


def prepare_helper(adb):
    adb.run("push", str(LOCAL_HELPER), REMOTE_HELPER)
    return inspect(adb)


def inspect(adb):
    output = adb.helper("inspect").decode()
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def show_status(adb):
    info = check_device(adb)
    # Read-only status: no helper deployment and no filesystem changes.
    shell_ns = adb.text("readlink /proc/self/ns/mnt")
    init_ns = adb.text("readlink /proc/1/ns/mnt")
    if shell_ns == init_ns:
        read_command = f"cat {TARGET}"
    else:
        if adb.shell(f"test -x {BUSYBOX}", check=False).returncode:
            raise Error("Mount namespaces differ and KernelSU BusyBox is unavailable; refusing a mixed-namespace status.")
        read_command = shlex.join([BUSYBOX, "nsenter", "-t", "1", "-m", "/system/bin/cat", TARGET])
    original = adb.run("exec-out", read_command).stdout
    root = ET.fromstring(original)
    declarations = [node.tag for node in root if node.get("name") == FEATURE]
    print(json.dumps({
        **info,
        "framework_has_cn_google_services": feature_value(adb),
        "xml_declarations": declarations,
        "xml_sha256": hashlib.sha256(original).hexdigest(),
        "shell_mount_namespace": shell_ns,
        "init_mount_namespace": init_ns,
        "xml_read_mount_namespace": init_ns,
        "xml_mount_in_init_namespace": adb.text(
            f"awk '$2 == \"{TARGET}\" {{ print }}' /proc/1/mounts"
        ),
    }, indent=2))


def refresh_android(adb, expected):
    if adb.shell(f"test -x {KSUD}", check=False).returncode:
        raise Error("KernelSU ksud is unavailable. XML state is prepared, but Android has not been refreshed; no full reboot was attempted.")
    before = adb.text("cat /proc/sys/kernel/random/boot_id")
    old_pid = adb.text("pidof system_server")
    adb.shell(f"{KSUD} soft-reboot")
    print("Refreshing Android with ksud soft-reboot; keeping the current kernel.", flush=True)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            new_pid = adb.text("pidof system_server")
            ready = adb.text("getprop sys.boot_completed") == "1"
            matched = bool(new_pid and new_pid != old_pid and ready and feature_value(adb) == expected)
        except (subprocess.TimeoutExpired, Error):
            matched = False
        if matched:
            after = adb.text("cat /proc/sys/kernel/random/boot_id")
            if after != before:
                raise Error("Kernel boot ID changed unexpectedly; check the device before continuing.")
            if adb.text("id -u") != "0":
                raise Error("Root was lost after the Android refresh.")
            print(f"Verified: {FEATURE}={str(expected).lower()}, root=0, kernel boot ID unchanged.")
            return
        time.sleep(2)
    raise Error("Android refresh verification timed out. Run status to inspect the current state; no retry or full reboot was triggered.")


def apply(adb, dry_run=False, no_restart=False):
    check_device(adb)
    state = prepare_helper(adb)
    if state["mount"] == "foreign":
        raise Error("Another mount covers the XML; no override was applied.")
    if state["mount"] == "owned":
        print("This script's XML bind is already active; no mount is stacked.")
        if not dry_run and not no_restart and feature_value(adb):
            refresh_android(adb, expected=False)
        return
    original = adb.helper("read-xml")
    digest = hashlib.sha256(original).hexdigest()
    if digest != state["xml_sha256"]:
        raise Error("ROM XML changed during inspection; rerun to inspect the new state.")
    patched = transform_xml(original)
    if dry_run:
        print("Validated XML transformation. No bind and no Android restart were performed.")
        print(patched.decode())
        return
    if not no_restart and adb.shell(f"test -x {KSUD}", check=False).returncode:
        raise Error("ksud is unavailable; refusing apply because the default Android refresh cannot run.")
    with tempfile.TemporaryDirectory(prefix="vivo-cn-google-") as temp:
        incoming = Path(temp) / "cn_feature.disabled.xml"
        incoming.write_bytes(patched)
        adb.run("push", str(incoming), REMOTE_INPUT)
    print(adb.helper("apply", digest, REMOTE_INPUT).decode().strip())
    if no_restart:
        print("XML bind is prepared. Android has not reread it; run apply again without --no-restart to refresh.")
    else:
        refresh_android(adb, expected=False)


def restore(adb, no_restart=False):
    check_device(adb)
    state = prepare_helper(adb)
    if state["mount"] == "foreign":
        raise Error("Another mount covers the XML; nothing was removed.")
    needs_refresh = not no_restart and not feature_value(adb)
    if needs_refresh and adb.shell(f"test -x {KSUD}", check=False).returncode:
        raise Error("ksud is unavailable; refusing restore because the default Android refresh cannot run. Use --no-restart only if you will refresh Android separately.")
    print(adb.helper("restore").decode().strip())
    if no_restart:
        print("Original XML is visible; cached framework features have not been refreshed.")
    elif needs_refresh:
        refresh_android(adb, expected=True)
    else:
        print("Verified: original XML visible and cn.google.services=true.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default=SERIAL, help="ADB serial (default: this Vivo)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="Read current XML and cached feature state")
    apply_parser = commands.add_parser("apply", help="Disable CN feature for this running kernel session")
    apply_parser.add_argument("--dry-run", action="store_true", help="Validate only; deploy helper but do not mount or restart")
    apply_parser.add_argument("--no-restart", action="store_true", help="Prepare XML bind without refreshing Android")
    restore_parser = commands.add_parser("restore", help="Remove this script's bind and restore the original feature")
    restore_parser.add_argument("--no-restart", action="store_true")
    args = parser.parse_args(argv)
    adb = Adb(args.serial)
    try:
        if args.command == "status":
            show_status(adb)
        elif args.command == "apply":
            apply(adb, dry_run=args.dry_run, no_restart=args.no_restart)
        else:
            restore(adb, no_restart=args.no_restart)
    except (Error, OSError, ET.ParseError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

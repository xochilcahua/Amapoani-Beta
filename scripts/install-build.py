"""Publish a fully staged macOS app. Preserve the identity that owns desktop access."""

import ctypes
import fcntl
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
CURRENT = ROOT / "build/current"
BUNDLE_NAME = "Amapoani.app"
LEGACY_NAME = "AHAMPO.app"


def requirement(bundle):
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "-r-", bundle], capture_output=True, text=True, check=True
    )
    for line in (result.stderr + result.stdout).splitlines():
        if line.removeprefix("# ").startswith("designated => "):
            return line.split("designated => ", 1)[1]
    raise ValueError(f"Cannot read signing requirement for {bundle}.")


def install(source, output):
    with (source / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    identifiers = {"local.ahampo.capsule"}
    if output != CURRENT:
        identifiers.add("local.ahampo.preview")
    if (info.get("CFBundleIdentifier") not in identifiers or
        (info.get("CFBundleExecutable"), info.get("CFBundleName")) != ("AHAMPO", "Amapoani")):
        raise ValueError("Choose a staged Amapoani app.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", source], check=True)
    output.mkdir(parents=True, exist_ok=True)
    destination = output / BUNDLE_NAME
    if source == destination:
        raise ValueError("The staged app and installation must have different paths.")
    lock = os.open(output, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = destination
        legacy = output / LEGACY_NAME
        if output == CURRENT and legacy.exists():
            if destination.exists():
                raise ValueError("Both app names exist in the installation folder. Resolve the duplicate before updating.")
            previous = legacy
        if output == CURRENT:
            new_rule = requirement(source)
            if "certificate" not in new_rule and "anchor" not in new_rule:
                raise ValueError("The current app needs a certificate-backed signature. Set AMAPOANI_SIGN_IDENTITY, or use AMAPOANI_OUTPUT_DIR for a preview.")
            if previous.exists():
                old_rule = requirement(previous)
                # Only the first migration from our ad hoc builds changes identity.
                if not old_rule.startswith("cdhash "):
                    for bundle, rule in ((source, old_rule), (previous, new_rule)):
                        subprocess.run(["/usr/bin/codesign", "--verify", "-R=" + rule, bundle], check=True)
        if not previous.exists():
            source.rename(destination)
            return destination
        active = subprocess.run(
            ["/usr/sbin/lsof", "-n", "-P", "-a", "-d", "txt", "-t", "--",
             previous / "Contents/MacOS/AHAMPO"], capture_output=True
        )
        if active.returncode != 1 or active.stderr:
            raise ValueError(f"Quit the running copy of {previous} before installing an update, or verify it has closed.")
        archive = Path(tempfile.mkdtemp(prefix="previous-build.", dir=ROOT / "work"))
        if previous != destination:
            retired = archive / previous.name
            previous.rename(retired)
            try:
                source.rename(destination)
            except OSError:
                retired.rename(previous)
                archive.rmdir()
                raise
            return destination
        # On macOS RENAME_SWAP exchanges the directories in one filesystem operation.
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renamex_np(os.fsencode(source), os.fsencode(destination), 0x00000002) != 0:
            error = ctypes.get_errno()
            archive.rmdir()
            raise OSError(error, os.strerror(error))
        try:
            source.rename(archive / destination.name)
        except OSError:
            # The old app is still at source. Restore it before reporting failure.
            if libc.renamex_np(os.fsencode(source), os.fsencode(destination), 0x00000002) != 0:
                raise ValueError(f"The previous build is preserved at {source}.")
            archive.rmdir()
            raise
        return destination
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        print(install(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

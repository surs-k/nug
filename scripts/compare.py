#!/usr/bin/env python3

# Ai - compare
#      what the old system had that this one does not, read from the copy of
#      v1 that prep.sh left on the data disk as @old-system
#      it only reads, nothing here changes either system, bringing something
#      over is compare.sh
#
#      compare.py scan [--old PATH] [--lines]   the list, as JSON, or one tab-separated
#                                               line each: id, kind, title, why, waits_for
#      compare.py owner PATH [--old PATH]       the package that made PATH in v1, if any
#
#      four kinds of item, each worded for a person, not a package manager:
#        package   an app v1 had, that this PC does not
#        config    a setting file in /etc, changed or made by hand in v1
#        stray     a file outside home that no package made, in /usr or /srv
#        local     what lives in /opt and /usr/local
#      a file this install writes itself is counted, never offered, because
#      bringing v1's copy over would undo what v2 set on purpose

import argparse
import filecmp
import hashlib
import json
import os
import sys
from pathlib import Path

OLD = Path("/mnt/data-root/@old-system")
SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent

# Ai - how far one scan goes before it stops counting, so a huge tree is quick
COUNT_LIMIT = 5000

# Ai - files this scan could not read, run as root nothing is hidden, run as
#      you the few that only root can read are counted and left out
UNREADABLE = [0]

# Ai - /etc files made by the system itself or by the install, never by hand
#      a prefix ends with /, anything else is one exact path
ETC_SKIP = (
    "/etc/passwd", "/etc/shadow", "/etc/group", "/etc/gshadow", "/etc/subuid", "/etc/subgid",
    "/etc/passwd-", "/etc/shadow-", "/etc/group-", "/etc/gshadow-",
    "/etc/machine-id", "/etc/hostname", "/etc/adjtime", "/etc/localtime", "/etc/mtab",
    "/etc/resolv.conf", "/etc/os-release", "/etc/ld.so.cache", "/etc/.pwd.lock",
    "/etc/.updated", "/etc/shells", "/etc/environment",
    "/etc/ssl/", "/etc/ca-certificates/", "/etc/pki/", "/etc/pacman.d/gnupg/",
    "/etc/udev/hwdb.bin", "/etc/cryptsetup-keys.d/", "/etc/ssh/ssh_host_",
    "/etc/mkinitcpio.d/", "/etc/kernel/", "/etc/limine.conf", "/etc/default/limine",
    "/etc/systemd/system/", "/etc/mullvad-vpn/", "/etc/tailscale/",
)

# Ai - never part of a stray or local item: caches the system rebuilds itself
GENERATED_DIRS = {"__pycache__", "lost+found", ".cache"}
GENERATED_SUFFIX = (".pyc", ".cache", ".compiled")
GENERATED_NAMES = {"giomodule.cache", "loaders.cache", "dir", "fonts.dir", "fonts.scale"}
USR_SKIP = ("/usr/local", "/usr/lib/modules", "/usr/share/mime", "/usr/lib/locale")


#    The two package databases

def read_db(root):
    """Everything pacman knows under ROOT: packages, who owns which path, the
    md5 of each setting file as the package shipped it."""
    local = Path(root) / "var/lib/pacman/local"
    pkgs, owner, backup = {}, {}, {}
    if not local.is_dir():
        return pkgs, owner, backup
    for d in local.iterdir():
        desc = d / "desc"
        if not desc.is_file():
            continue
        name, explicit, text = "", True, ""
        section = ""
        for line in desc.read_text(errors="replace").splitlines():
            if line.startswith("%") and line.endswith("%"):
                section = line.strip("%")
                continue
            if not line:
                continue
            if section == "NAME":
                name = line
            elif section == "REASON" and line.strip() == "1":
                explicit = False
            elif section == "DESC":
                text = line
        if not name:
            continue
        pkgs[name] = {"explicit": explicit, "desc": text}
        files = d / "files"
        if not files.is_file():
            continue
        section = ""
        for line in files.read_text(errors="replace").splitlines():
            if line.startswith("%") and line.endswith("%"):
                section = line.strip("%")
                continue
            if not line:
                continue
            if section == "FILES":
                owner["/" + line.rstrip("/")] = name
            elif section == "BACKUP":
                path, _, md5 = line.partition("\t")
                backup["/" + path] = (name, md5)
    return pkgs, owner, backup


def md5_of(path):
    h = hashlib.md5()
    try:
        with open(path, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
    except OSError:
        UNREADABLE[0] += 1
        return None
    return h.hexdigest()


#    This install writes it itself

def written_by_install(path):
    """True when a script or template in the repo names this path, so v2 sets
    it on purpose and v1's version must not replace it."""
    global _TEXT
    if _TEXT is None:
        parts = []
        for base in (SCRIPTS, REPO / "config"):
            for f in base.rglob("*"):
                if f.is_file() and f.suffix in ("", ".sh", ".py", ".env", ".list", ".conf", ".toml", ".jsonc", ".css"):
                    try:
                        parts.append(f.read_text(errors="replace"))
                    except OSError:
                        pass
        _TEXT = "\n".join(parts)
    return path in _TEXT


_TEXT = None


#    Small helpers

def same(a, b):
    """The same file in both systems: same kind, same content or link."""
    try:
        if os.path.islink(a) or os.path.islink(b):
            return os.path.islink(a) and os.path.islink(b) and os.readlink(a) == os.readlink(b)
        return os.path.isfile(a) and os.path.isfile(b) and filecmp.cmp(a, b, shallow=False)
    except OSError:
        return False


def size_of(path, limit=COUNT_LIMIT):
    """Bytes and file count of a path, counting stops at COUNT_LIMIT files."""
    if os.path.islink(path) or os.path.isfile(path):
        try:
            return os.lstat(path).st_size, 1
        except OSError:
            return 0, 1
    total = count = 0
    for base, dirs, files in os.walk(path):
        for f in files:
            count += 1
            try:
                total += os.lstat(os.path.join(base, f)).st_size
            except OSError:
                pass
            if count >= limit:
                return total, count
    return total, count


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000


def generated(name):
    return name in GENERATED_DIRS or name in GENERATED_NAMES or name.endswith(GENERATED_SUFFIX)


def skipped(path, skip):
    # Ai - a skip ending in / or _ covers everything that starts with it
    return any(path == s or (s.endswith(("/", "_")) and path.startswith(s)) for s in skip)


#    The scan

def packages(old_pkgs, new_pkgs):
    items = []
    for name in sorted(old_pkgs):
        if not old_pkgs[name]["explicit"] or name in new_pkgs:
            continue
        items.append({
            "id": f"package:{name}", "kind": "package", "title": name,
            "why": old_pkgs[name]["desc"] or "an app v1 had",
            "action": "Install it",
        })
    return items


def config(old, new, old_owner, old_backup, new_pkgs):
    items, managed = [], 0

    def judge(path, why):
        nonlocal managed
        src, dst = old + path, new + path
        if not os.path.lexists(src) or skipped(path, ETC_SKIP):
            return None
        if not os.path.islink(src) and not os.access(src, os.R_OK):
            UNREADABLE[0] += 1
            return None
        if same(src, dst):
            return None
        if written_by_install(path):
            managed += 1
            return None
        item = {
            "id": f"config:{path}", "kind": "config", "title": path, "why": why,
            "path": path, "state": "differs" if os.path.lexists(dst) else "missing",
            "action": "Bring it over",
        }
        owner = old_owner.get(path) or old_backup.get(path, ("",))[0]
        if owner and owner not in new_pkgs:
            item["waits_for"] = owner
        return item

    # Ai - a setting file a package shipped, that v1 changed by hand
    for path, (_pkg, md5) in sorted(old_backup.items()):
        src = old + path
        if os.path.isfile(src) and not os.path.islink(src) and md5_of(src) not in (None, md5):
            item = judge(path, "a setting you changed by hand in v1")
            if item:
                items.append(item)
    # Ai - a file in /etc that no package made, so someone did
    for base, dirs, files in os.walk(old + "/etc", onerror=lambda _e: UNREADABLE.__setitem__(0, UNREADABLE[0] + 1)):
        dirs[:] = sorted(d for d in dirs if not generated(d))
        for f in sorted(files):
            path = os.path.join(base, f)[len(old):]
            if path in old_owner or path in old_backup:
                continue
            item = judge(path, "a setting file you made by hand in v1")
            if item:
                items.append(item)
    return items, managed


def unowned(old, new, top, owner, skip, why, kind):
    """The shallowest paths under TOP that no package made, a whole folder is
    one item, so a hand-installed program is a line and not five thousand."""
    items = []
    root = old + top
    if not os.path.isdir(root):
        return items

    def walk(directory):
        try:
            entries = sorted(os.scandir(directory), key=lambda e: e.name)
        except OSError:
            UNREADABLE[0] += 1
            return
        for e in entries:
            path = e.path[len(old):]
            if generated(e.name) or skipped(path, skip):
                continue
            if path in owner:
                if e.is_dir(follow_symlinks=False):
                    walk(e.path)
                continue
            if e.is_dir(follow_symlinks=False):
                nbytes, count = size_of(e.path)
                if count == 0:
                    continue
            else:
                nbytes, count = size_of(e.path)
            if os.path.lexists(new + path) and (e.is_dir(follow_symlinks=False) or kind == "local" or same(e.path, new + path)):
                continue
            note = human(nbytes) + ("+" if count >= COUNT_LIMIT else "")
            items.append({
                "id": f"{kind}:{path}", "kind": kind, "title": path,
                "why": f"{why}, {note}" + (f", {count}{'+' if count >= COUNT_LIMIT else ''} files" if count > 1 else ""),
                "path": path, "bytes": nbytes, "action": "Bring it over",
            })

    walk(root)
    return items


def local_items(old, new, owner):
    # Ai - /opt by its folders, /usr/local one level in, where bin and lib hold the files
    items = []
    opt = old + "/opt"
    if os.path.isdir(opt):
        items += unowned(old, new, "/opt", owner, (), "installed by hand in /opt", "local")
    base = old + "/usr/local"
    if os.path.isdir(base):
        for sub in sorted(os.listdir(base)):
            if os.path.isdir(os.path.join(base, sub)) and not os.path.islink(os.path.join(base, sub)):
                items += unowned(old, new, f"/usr/local/{sub}", owner, (), "installed by hand in /usr/local", "local")
    return items


def scan(old=OLD, new="/"):
    old, new = str(old).rstrip("/"), str(new).rstrip("/")
    UNREADABLE[0] = 0
    if not os.path.isdir(old + "/etc"):
        raise SystemExit(f"no old system at {old or '/'}")
    old_pkgs, old_owner, old_backup = read_db(old)
    new_pkgs, _, _ = read_db(new or "/")
    cfg, managed = config(old, new, old_owner, old_backup, new_pkgs)
    items = packages(old_pkgs, new_pkgs) + cfg
    items += unowned(old, new, "/usr", old_owner, USR_SKIP, "no package made it", "stray")
    items += unowned(old, new, "/srv", old_owner, (), "no package made it", "stray")
    items += local_items(old, new, old_owner)
    return {"old": old, "managed": managed, "unreadable": UNREADABLE[0], "items": items}


def main():
    ap = argparse.ArgumentParser(prog="compare.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--old", default=str(OLD))
    s.add_argument("--new", default="/")
    s.add_argument("--lines", action="store_true")
    o = sub.add_parser("owner")
    o.add_argument("path")
    o.add_argument("--old", default=str(OLD))
    a = ap.parse_args()
    if a.cmd == "owner":
        _, owner, backup = read_db(a.old)
        print(owner.get(a.path) or backup.get(a.path, ("",))[0])
        return
    found = scan(a.old, a.new)
    if a.lines:
        for i in found["items"]:
            print("\t".join((i["id"], i["kind"], i["title"], i["why"], i.get("waits_for", ""))))
        return
    json.dump(found, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()

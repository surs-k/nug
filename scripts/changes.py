#!/usr/bin/env python3

# Ai - changes
#      a calm place to manage, learn and improve your projects, any git repo
#      one screen at a time: your projects, then one project's three views,
#      then one item, Back always goes one step up:
#        Problems   what is wrong right now, quiet ones included
#        Changes    what changed, in plain words, the code one click away
#        Notes      your questions, ready to paste into a Claude chat
#      nothing leaves this PC by itself, Ask Claude only copies to the clipboard
#
#      changes                     open the window
#      changes open NAME[/ITEM]    open a project, or one item in it
#      changes --check             check every project, used by the hourly timer
#      changes --install           put Changes in the app launcher, once

import html
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tomllib
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

from PyQt6.QtCore import QObject, QRunnable, QSettings, QSize, Qt, QThreadPool, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFontDatabase, QGuiApplication, QKeySequence, QPalette, QShortcut
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QFrame, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
    QMenu, QMessageBox, QPlainTextEdit, QPushButton, QScrollArea, QTextEdit, QToolButton,
    QVBoxLayout, QWidget,
)


#    Places

CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "changes"
DATA = Path.home() / ".local/share/changes"
CACHE = Path.home() / ".cache/changes"
PROJECTS = CONFIG / "projects.json"
SUMMARY = CACHE / "problems.txt"
SEEN = CACHE / "problems.json"
REBUILD = Path(os.environ.get("REBUILD_REPO", Path.home() / "rebuild"))
SOCKET = f"changes-{os.getuid()}"
OLD_SYSTEM = Path("/mnt/data-root/@old-system")


#    From v1

# Ai - what the old install had that this one lacks, read from the copy of v1
#      that prep.sh saved on the data disk, the scan itself is compare.py in
#      the install repo, bringing something over is rebuild compare in a
#      terminal, because it needs your password
COMPARE_KINDS = [
    ("package", "Apps v1 had"),
    ("config", "Settings changed or made by hand in v1"),
    ("stray", "Files outside home that no app made"),
    ("local", "Programs in /opt and /usr/local"),
]


def compare_available():
    return (OLD_SYSTEM / "etc").is_dir()


def compare_scan():
    script = REBUILD / "scripts/compare.py"
    if not script.is_file():
        raise RuntimeError(f"{script} is not there, pull the install repo first")
    r = subprocess.run(["python3", "-I", str(script), "scan"], capture_output=True, text=True, timeout=900)
    if r.returncode:
        raise RuntimeError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "the scan failed")
    return json.loads(r.stdout)


def in_terminal(command):
    # Ai - a terminal of its own, it stays open until Enter so the result can be read
    script = f'{command}; echo; read -rp "Press Enter to close  " _'
    for term in ("kitty", "foot", "alacritty", "xterm"):
        if shutil.which(term):
            args = [term, "bash", "-c", script] if term == "kitty" else [term, "-e", "bash", "-c", script]
            return subprocess.run(args).returncode
    raise RuntimeError("no terminal program found to run rebuild in")


#    Tokens

# Ai - every size, colour and limit in one place, nothing below sets its own
#      the look follows Manager: one column, rounded cards, quiet text for
#      the less important line. Red, amber, green and blue each always mean
#      the same thing: wrong now, worth a look, fine, built in
TOKENS = {
    "s1": 4, "s2": 8, "s3": 12, "s4": 16, "s5": 24, "s6": 32,
    "radius": 12, "card_radius": 16,
    "fs_xs": 12, "fs_s": 13, "fs_m": 15, "fs_b": 17, "fs_l": 20, "fs_xl": 28,
    "hit": 44, "row": 56, "column": 680,
    "large": 1.15,      # Larger text multiplies every size by this
    "show": 7,          # rows a card shows before Show more
    "more": 20,         # rows each Show more adds
    "toast_ms": 2600,
    "tip_days": 3,      # a tip shows on this many days, then fades away
    "diff_lines": 4000,
    "ask_lines":  300,
    "log_limit":  500,
}

THEMES = {
    "Slate": {
        "bg": "#4b4f55", "surface": "#575b62", "surface2": "#63676f", "raised": "#6b7078",
        "line": "rgba(255,255,255,28)", "track": "rgba(0,0,0,51)",
        "text": "#f1f3f4", "text2": "#d3d7db", "text3": "#b8bdc2",
        "accent": "#c3b5f7", "accent_ink": "#2a2540",
        "danger": "#ffa8a1", "warn": "#ffd27a", "ok": "#8fd9b6", "info": "#8fc7ff",
    },
    "Midnight": {
        "bg": "#0e1014", "surface": "#1b1e25", "surface2": "#272b34", "raised": "#323743",
        "line": "rgba(255,255,255,23)", "track": "rgba(255,255,255,18)",
        "text": "#eef0f3", "text2": "#b7bec8", "text3": "#8f97a3",
        "accent": "#c3b5f7", "accent_ink": "#2a2540",
        "danger": "#ffa8a1", "warn": "#ffd27a", "ok": "#8fd9b6", "info": "#8fc7ff",
    },
    "Paper": {
        "bg": "#f6f3ee", "surface": "#ffffff", "surface2": "#ebe6de", "raised": "#ffffff",
        "line": "rgba(0,0,0,26)", "track": "rgba(0,0,0,14)",
        "text": "#1d1b19", "text2": "#55504a", "text3": "#857f77",
        "accent": "#5b46b8", "accent_ink": "#ffffff",
        "danger": "#b3261e", "warn": "#8a5a00", "ok": "#1e7a4f", "info": "#1d5fa8",
    },
}

# Ai - the theme in use, apply_theme fills it
T = dict(THEMES["Slate"])

TONES = {"bad": "danger", "warn": "warn", "good": "ok", "info": "info", "accent": "accent", "none": "text3"}


#    Git

def git(repo, *args):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def is_repo(path):
    return bool(path) and bool(git(path, "rev-parse", "--git-dir"))


def has_remote(repo):
    return bool(git(repo, "remote").strip())


def fetch(repo):
    # Ai - quiet, an offline PC keeps what it fetched last time
    if has_remote(repo):
        try:
            subprocess.run(["git", "-C", str(repo), "fetch", "-q"], capture_output=True, timeout=60)
        except subprocess.TimeoutExpired:
            pass


def refs(repo):
    # Ai - local branches first, then the remote ones
    out = git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes")
    return [n for n in out.split() if not n.endswith("/HEAD")]


def ref_of(project):
    return project.get("ref") or "HEAD"


def span(project, ref):
    base = project.get("base")
    return f"{base}..{ref}" if base and base != ref else ref


def entries(project, ref):
    out = git(project["repo"], "log", f"-{TOKENS['log_limit']}", "--date=short",
              "--format=%H%x1f%ad%x1f%an%x1f%s%x1f%b%x1e", span(project, ref),
              "--", *project.get("paths", []))
    rows = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if rec:
            h, date, author, subject, body = rec.split("\x1f", 4)
            rows.append({"kind": "change", "hash": h, "date": date, "author": author,
                         "subject": subject, "body": body})
    return rows


def parse(body):
    # Ai - a commit can explain itself with What, Why, For you, Values and
    #      Problems lines, a field runs until the next field or a blank line
    out, key = {}, None
    for line in body.splitlines():
        m = re.match(r"^(What|Why|For you|Values|Problems):\s*(.*)$", line)
        if m:
            key = m.group(1)
            out[key] = m.group(2)
        elif key and line.strip():
            out[key] += " " + line.strip()
        else:
            key = None
    return out


def numstat(project, args):
    rows = []
    for line in git(project["repo"], *args, "--numstat", "-M", "--", *project.get("paths", [])).splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            rows.append((parts[2], parts[0], parts[1]))
    return rows


def patch(project, args):
    return git(project["repo"], *args, "--patch", "-M", "--", *project.get("paths", []))


#    Projects

# Ai - a project is a git repo, optionally narrowed to some paths in it
#        ref         what to follow, a branch, empty is whatever is checked out
#        base        list only what changed since this, and offer a compare
#        problems    a problems.toml in the repo, see docs/problems.toml
#        git_checks  the built-in checks for unsaved and unshared work

def new_project(name, repo, **kw):
    p = {"id": uuid.uuid4().hex[:8], "name": name, "repo": str(repo), "paths": [],
         "ref": "", "base": "", "problems": "", "git_checks": True}
    p.update(kw)
    return p


def default_projects():
    # Ai - the first run finds the install repo and adds it twice: the PC
    #      install itself, and this app, which lives inside it
    out = []
    if is_repo(REBUILD):
        out.append(new_project("PC install", REBUILD, ref="origin/v2", base="origin/v1",
                               problems="docs/problems.toml"))
        out.append(new_project("Changes app", REBUILD, ref="origin/v2", base="origin/v1",
                               paths=["scripts/changes.py", "docs/changes-problems.toml"],
                               problems="docs/changes-problems.toml", git_checks=False))
    return out


def load_projects():
    try:
        return json.loads(PROJECTS.read_text())
    except (OSError, ValueError):
        projects = default_projects()
        save_projects(projects)
        migrate_notes(projects)
        return projects


def save_projects(projects):
    CONFIG.mkdir(parents=True, exist_ok=True)
    tmp = PROJECTS.with_suffix(".tmp")
    tmp.write_text(json.dumps(projects, indent=1))
    tmp.replace(PROJECTS)


#    Notes

def notes_file(project):
    return DATA / "notes" / f"{project['id']}.json"


def load_notes(project):
    try:
        return json.loads(notes_file(project).read_text())
    except (OSError, ValueError):
        return {}


def save_notes(project, notes):
    f = notes_file(project)
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(notes, indent=1))
    tmp.replace(f)


def migrate_notes(projects):
    # Ai - notes from the single-project version move to the PC install
    old = DATA / "notes.json"
    if old.exists() and projects:
        try:
            save_notes(projects[0], json.loads(old.read_text()))
            old.rename(old.with_suffix(".json.moved"))
        except (OSError, ValueError):
            pass


#    Problems

# Ai - on: wrong right now, design: how it was built, fixed in a later
#      version, unknown: the check could not tell, clear: fine
STATES = {
    "on":      "Wrong right now",
    "design":  "Built in",
    "unknown": "Could not check",
    "clear":   "Fine",
}
ORDER = ["on", "design", "unknown", "clear"]
STATE_TONE = {"on": "bad", "design": "info", "unknown": "warn", "clear": "good"}

# Ai - the built-in checks, for any project with git_checks on
GIT_CHECKS = [
    {"id": "git-unsaved", "area": "Recovery", "quiet": True,
     "title": "Work that is not saved in git",
     "means": "Files changed since the last commit. If something breaks, these changes have no copy to go back to.",
     "now": "Commit them, or ask Claude what they are first."},
    {"id": "git-unshared", "area": "Recovery", "quiet": True,
     "title": "Commits that exist only on this PC",
     "means": "If this disk fails, these commits are gone. They are not on GitHub or any other remote.",
     "now": "Push them."},
    {"id": "git-behind", "area": "Management", "quiet": True,
     "title": "Newer changes are waiting",
     "means": "The remote has commits this copy does not have yet.",
     "now": "Pull them."},
    {"id": "git-secrets", "area": "Security", "quiet": True,
     "title": "Files that look like secrets are in git",
     "means": "Keys or password files saved in git stay in its history, and go wherever the repo is copied.",
     "now": "Ask Claude how to remove them from the history, then change those secrets."},
]

SECRET_NAMES = re.compile(r"(^|/)(\.env(\..*)?|id_(rsa|ed25519|ecdsa)|.*\.(pem|key|p12|pfx|kdbx)|"
                          r"credentials(\.json)?|secrets?\.(json|ya?ml|toml))$", re.I)


def git_check(repo, cid):
    tracked = bool(git(repo, "rev-parse", "--abbrev-ref", "@{u}").strip())
    if cid == "git-unsaved":
        lines = git(repo, "status", "--porcelain").splitlines()
        if not lines:
            return "clear", ""
        return "on", "\n".join(l[3:] for l in lines[:20]) + ("\n…" if len(lines) > 20 else "")
    if cid == "git-unshared":
        if not has_remote(repo):
            return "on", "this project has no remote at all"
        if not tracked:
            return "unknown", "this branch does not follow a remote branch"
        n = git(repo, "rev-list", "--count", "@{u}..HEAD").strip()
        return ("on", f"{n} commit(s)") if n not in ("", "0") else ("clear", "")
    if cid == "git-behind":
        if not tracked:
            return "unknown", "this branch does not follow a remote branch"
        n = git(repo, "rev-list", "--count", "HEAD..@{u}").strip()
        return ("on", f"{n} commit(s)") if n not in ("", "0") else ("clear", "")
    if cid == "git-secrets":
        hits = [f for f in git(repo, "ls-files").splitlines()
                if SECRET_NAMES.search(f) and not f.endswith((".example", ".sample"))]
        return ("on", "\n".join(hits[:20])) if hits else ("clear", "")
    return "unknown", ""


def problem_list(project):
    # Ai - read from the followed branch, so a new problem shows without a pull
    path = project.get("problems")
    if not path:
        return []
    text = git(project["repo"], "show", f"{ref_of(project)}:{path}")
    if not text:
        try:
            text = (Path(project["repo"]) / path).read_text()
        except OSError:
            return []
    try:
        return tomllib.loads(text).get("problem", [])
    except tomllib.TOMLDecodeError:
        return [{"id": "problems-file", "title": "The problems file has a mistake in it",
                 "area": "Management", "quiet": False, "means": f"{path} could not be read.",
                 "now": "Ask Claude to fix the file."}]


def run_check(p, repo):
    # Ai - as you, never as root, from inside the project, five seconds at most
    if "check" not in p:
        return "design", ""
    try:
        r = subprocess.run(["sh", "-c", p["check"]], cwd=repo, capture_output=True,
                           text=True, timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        return "unknown", "the check did not finish"
    return {0: "on", 1: "clear"}.get(r.returncode, "unknown"), r.stdout.strip()


def check_project(project):
    problems = [dict(p, source="file") for p in problem_list(project)]
    if project.get("git_checks", True):
        problems += [dict(p, source="git") for p in GIT_CHECKS]
    repo = project["repo"]

    def one(p):
        return git_check(repo, p["id"]) if p["source"] == "git" else run_check(p, repo)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = dict(zip([p["id"] for p in problems], pool.map(one, problems)))
    return problems, results


def fixed_by(project, problems):
    # Ai - which changes name a problem on their Problems: line
    ids = {p["id"] for p in problems}
    out = {}
    for row in entries(project, ref_of(project)):
        for pid in re.findall(r"[a-z0-9-]+", parse(row["body"]).get("Problems", "")):
            if pid in ids:
                out.setdefault(pid, []).append(row)
    return out


def write_summary(found):
    # Ai - found is [(project, problems, results)], the terminal prints the
    #      summary, and a problem not seen last time sends one notification
    lines, now_on, titles = [], [], {}
    for project, problems, results in found:
        for p in problems:
            if results[p["id"]][0] == "on":
                key = f"{project['id']}/{p['id']}"
                lines.append(f"    {project['name']:<14}{p['title']}")
                now_on.append(key)
                titles[key] = f"{project['name']}: {p['title']}"
    CACHE.mkdir(parents=True, exist_ok=True)
    if lines:
        head = f"  {len(lines)} problem{'s' if len(lines) != 1 else ''} wrong right now, open Changes to see why"
        SUMMARY.write_text("\n".join([head] + lines) + "\n\n")
    else:
        SUMMARY.write_text("")
    try:
        seen = set(json.loads(SEEN.read_text()))
    except (OSError, ValueError):
        seen = set()
    new = [k for k in now_on if k not in seen]
    SEEN.write_text(json.dumps(sorted(now_on)))
    if new and shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "Changes", "New problem",
                        "\n".join(titles[k] for k in new)], capture_output=True)
    return len(lines)


def check_all(do_fetch=True):
    found = []
    for project in load_projects():
        if not is_repo(project["repo"]):
            continue
        if do_fetch:
            fetch(project["repo"])
        found.append((project, *check_project(project)))
    return write_summary(found)


#    Prompts

# Ai - what Ask Claude copies, each one says who you are, what you want,
#      and gives Claude the facts it needs, so the first answer is useful

def prompt_change(project, row, note):
    f = parse(row.get("body", ""))
    args = ["show", "--format=", row["hash"]]
    files = numstat(project, args)
    lines = patch(project, args).splitlines()
    cut = lines[:TOKENS["ask_lines"]]
    out = [
        "I am learning how my project works and I want to improve it.",
        "Explain this change in plain words: what it does, why it matters, and anything risky in it.",
        "Then suggest one small improvement. Keep it short, walls of text overwhelm me.",
        "",
        f"Project: {project['name']}",
        f"Change: {row['subject']} ({row['hash'][:7]}, {row['date']}, by {row.get('author', '?')})",
    ]
    out += [f"{k}: {v}" for k, v in f.items()]
    if note:
        out.append(f"My note: {note}")
    out += ["", "Files:"] + [f"  {p}  +{a} -{r}" for p, a, r in files[:40]]
    out += ["", "The change:", "```diff", *cut, "```"]
    if len(lines) > len(cut):
        out.append(f"(cut at {len(cut)} of {len(lines)} lines)")
    return "\n".join(out)


def prompt_problem(project, p, state, found, note):
    out = [
        "I need help with a problem in my project. I am not an expert, so go step by step,",
        "say what each step does and why, and warn me before anything that could lose data.",
        "",
        f"Project: {project['name']}",
        f"Problem: {p['title']} ({p.get('area', '')})",
        f"Status: {STATES[state]}",
        f"What it means: {p.get('means', '')}",
    ]
    if p.get("now"):
        out.append(f"Suggested fix: {p['now']}")
    if found:
        out += ["What the check found:", found]
    if p.get("check"):
        out += ["How it is checked:", "```sh", p["check"].strip(), "```"]
    if note:
        out.append(f"My note: {note}")
    return "\n".join(out)


def prompt_overview(project, problems, results):
    files = git(project["repo"], "ls-files", "--", *project.get("paths", [])).splitlines()
    log = git(project["repo"], "log", "-20", "--format=%ad  %s", "--date=short", ref_of(project),
              "--", *project.get("paths", [])).splitlines()
    on = [p for p in problems if results.get(p["id"], ("",))[0] in ("on", "design")]
    out = [
        "Here is an overview of one of my projects. I want to understand it and improve it",
        "without getting overwhelmed. Tell me in plain words what it is, the three things most",
        "worth improving first and why, and one first step.",
        "",
        f"Project: {project['name']}",
        f"Files ({len(files)}):", *[f"  {f}" for f in files[:200]],
    ]
    if len(files) > 200:
        out.append(f"  and {len(files) - 200} more")
    out += ["", "Recent changes:", *[f"  {l}" for l in log]]
    if on:
        out += ["", "Known problems:", *[f"  {STATES[results[p['id']][0]]}: {p['title']}" for p in on]]
    return "\n".join(out)


COMMIT_STYLE = """When you commit to my projects, write every commit message like this, so my
Changes app can explain it to me in plain words:

A short title, what changed, under 60 characters

What: what the change does, in plain words, one to three sentences.
Why: the problem it solves or the reason for it.
For you: what it means for me, and anything I have to do. Say "Nothing to do" if so.
Values: the values it serves, from: Security, Privacy, Recovery, Management,
  Efficiency, Visuals, Educating, Concise.
Problems: ids of problems in the project's problems.toml that this fixes, if any.

Keep each line simple. No jargon without a short explanation.
"""

PROBLEMS_STYLE = """Write a problems.toml for my project, so my Changes app can show its problems.
Each problem looks like this:

[[problem]]
id = "short-id"
title = "What is wrong, in plain words"
area = "Security"          # or Privacy, Recovery, Management, Efficiency, Visuals, Educating
quiet = true               # true if nothing on screen would tell me
means = "What it means for me, one or two sentences."
now = "What I can do about it today, if anything."
check = '''
# optional: a read-only shell check, run as me from the project folder
# exit 0 = the problem is there, 1 = it is not, anything else = could not tell
# what it prints is shown to me as what it found
'''

List only real problems you can see in the project. Keep the wording plain.
"""


#    Background

class Signals(QObject):
    done = pyqtSignal(object)


class Job(QRunnable):
    # Ai - slow work runs off screen, so the window never freezes, the
    #      result comes back on the window's own thread
    def __init__(self, fn):
        super().__init__()
        self.fn, self.signals = fn, Signals()
        self.setAutoDelete(False)

    def run(self):
        try:
            result = self.fn()
        except Exception as e:
            result = e
        self.signals.done.emit(result)


#    Look

def rgba(hexc, a):
    h = hexc.lstrip("#")
    return f"rgba({int(h[0:2], 16)},{int(h[2:4], 16)},{int(h[4:6], 16)},{a})"


def stylesheet(t, k):
    # Ai - the whole look, built from the tokens, so a theme is one dict
    fs = {n: round(TOKENS[f"fs_{n}"] * k) for n in ("xs", "s", "m", "b", "l", "xl")}
    r, cr = TOKENS["radius"], TOKENS["card_radius"]
    soft = rgba(t["accent"], 46)
    tones = "".join(
        f'QLabel[role="dot"][tone="{tone}"] {{ background: {t[key]}; }}\n'
        f'QLabel[role="pill"][tone="{tone}"] {{ color: {t[key]}; background: {rgba(t[key], 40)}; }}\n'
        for tone, key in TONES.items())
    rows = 'QFrame[role="row"], QFrame[role="cardh"], QFrame[role="more"], QFrame[role="addrow"]'
    return f"""
QWidget {{ color: {t['text']}; font-size: {fs['b']}px; }}
QMainWindow, QDialog, QMessageBox {{ background: {t['bg']}; }}
QScrollArea#page, QScrollArea#page > QWidget#qt_scrollarea_viewport, QWidget#canvas {{ background: {t['bg']}; border: 0; }}
QToolTip {{ background: {t['surface2']}; color: {t['text']}; border: 1px solid {t['line']}; padding: 6px 8px; }}

QLabel[role="title"] {{ font-size: {fs['xl']}px; font-weight: 700; }}
QLabel[role="sub"] {{ font-size: {fs['m']}px; color: {t['text2']}; }}
QLabel[role="cardt"] {{ font-weight: 700; }}
QLabel[role="meta"] {{ font-size: {fs['s']}px; color: {t['text2']}; }}
QLabel[role="lab"] {{ font-size: {fs['xs']}px; font-weight: 700; color: {t['text2']}; }}
QLabel[role="count"] {{ font-size: {fs['m']}px; color: {t['text2']}; }}
QLabel[role="chev"] {{ font-size: {fs['l']}px; color: {t['text3']}; }}
QLabel[role="emptyh"] {{ font-size: {fs['l']}px; font-weight: 700; }}
QLabel[role="emptyp"] {{ font-size: {fs['m']}px; color: {t['text2']}; }}
QLabel[role="dot"] {{ border-radius: 5px; background: {t['text3']}; }}
QLabel[role="pill"] {{ font-size: {fs['m']}px; font-weight: 700; border-radius: {r}px; padding: 4px 12px; }}
{tones}
QFrame[role="card"] {{ background: {t['surface']}; border-radius: {cr}px; }}
QFrame[role="coach"] {{ background: {soft}; border-radius: {cr}px; }}
QFrame[role="line"] {{ background: {t['line']}; border: 0; }}
{rows} {{ background: transparent; border: 2px solid transparent; border-radius: {r}px; }}
{rows.replace('"]', '"]:hover')} {{ background: {t['track']}; }}
{rows.replace('"]', '"]:focus')} {{ border-color: {t['accent']}; }}
QFrame[role="addrow"] {{ border: 1px dashed {t['text3']}; border-radius: {cr}px; }}
QLabel[role="link"] {{ color: {t['accent']}; font-size: {fs['m']}px; font-weight: 600; }}

QFrame[role="seg"] {{ background: {t['track']}; border-radius: {r}px; }}
QPushButton[role="segb"] {{ background: transparent; color: {t['text2']}; border: 2px solid transparent; border-radius: 10px;
    min-height: 36px; padding: 0 12px; font-size: {fs['m']}px; font-weight: 600; }}
QPushButton[role="segb"]:checked {{ background: {t['raised']}; color: {t['text']}; }}
QPushButton[role="segb"]:focus {{ border-color: {t['accent']}; }}

QPushButton {{ background: {t['track']}; color: {t['accent']}; border: 2px solid transparent; border-radius: {r}px;
    min-height: 40px; padding: 0 16px; font-weight: 600; }}
QPushButton:hover {{ background: {t['surface2']}; }}
QPushButton:focus {{ border-color: {t['accent']}; }}
QPushButton:disabled {{ color: {t['text3']}; }}
QPushButton[role="primary"] {{ background: {t['accent']}; color: {t['accent_ink']}; }}
QPushButton[role="primary"]:focus {{ border-color: {t['text']}; }}
QPushButton[role="flat"] {{ background: transparent; }}
QPushButton[role="flat"]:hover {{ background: {t['track']}; }}
QToolButton {{ background: transparent; border: 0; padding: 6px; font-weight: 600; }}

QLineEdit, QPlainTextEdit, QTextEdit, QComboBox {{ background: {t['track']}; color: {t['text']}; border: 2px solid transparent;
    border-radius: {r}px; padding: 6px 10px; selection-background-color: {t['accent']}; selection-color: {t['accent_ink']}; }}
QLineEdit:focus, QPlainTextEdit:focus, QTextEdit:focus, QComboBox:focus {{ border-color: {t['accent']}; }}
QComboBox QAbstractItemView {{ background: {t['surface2']}; border: 0; selection-background-color: {soft}; }}
QTextEdit#diff {{ font-size: {fs['s']}px; }}
QListWidget {{ background: {t['surface']}; border: 0; border-radius: {cr}px; padding: 4px; outline: 0; }}
QListWidget::item {{ padding: 10px 12px; border-radius: 10px; }}
QListWidget::item:selected {{ background: {soft}; color: {t['text']}; }}

QMenu {{ background: {t['surface2']}; border: 1px solid {t['line']}; padding: 6px; }}
QMenu::item {{ padding: 8px 28px 8px 16px; border-radius: 8px; }}
QMenu::item:selected {{ background: {soft}; }}
QMenu::item:disabled {{ color: {t['text3']}; }}
QMenu::separator {{ height: 1px; background: {t['line']}; margin: 6px 8px; }}

QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 2px; }}
QScrollBar::handle {{ background: {t['surface2']}; border-radius: 3px; min-height: 40px; min-width: 40px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ width: 0; height: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

QLabel#toast {{ background: {t['surface2']}; color: {t['text']}; border-radius: {cr}px; padding: 10px 18px; font-size: {fs['m']}px; }}
"""


def palette_of(t):
    # Ai - the same colours for the parts Qt draws itself, file pickers included
    R, pal = QPalette.ColorRole, QPalette()
    for role, key in [(R.Window, "bg"), (R.WindowText, "text"), (R.Base, "surface"), (R.AlternateBase, "surface2"),
                      (R.Text, "text"), (R.Button, "surface"), (R.ButtonText, "text"), (R.Highlight, "accent"),
                      (R.HighlightedText, "accent_ink"), (R.ToolTipBase, "surface2"), (R.ToolTipText, "text"),
                      (R.Link, "accent"), (R.PlaceholderText, "text3")]:
        pal.setColor(role, QColor(t[key]))
    for role in (R.WindowText, R.Text, R.ButtonText):
        pal.setColor(QPalette.ColorGroup.Disabled, role, QColor(t["text3"]))
    return pal


def apply_theme(app, name, large):
    T.clear()
    T.update(THEMES.get(name, THEMES["Slate"]))
    app.setStyle("Fusion")
    app.setPalette(palette_of(T))
    app.setStyleSheet(stylesheet(T, TOKENS["large"] if large else 1))


#    Parts

def label(text="", role="", tone="", rich=False, wrap=True, select=False):
    lab = QLabel(text)
    if role:
        lab.setProperty("role", role)
    if tone:
        lab.setProperty("tone", tone)
    lab.setWordWrap(wrap)
    lab.setTextFormat(Qt.TextFormat.RichText if rich else Qt.TextFormat.PlainText)
    if select or rich:
        lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse
                                    | Qt.TextInteractionFlag.LinksAccessibleByMouse)
    return lab


def para(text=""):
    return label(text, rich=True)


def dot(tone):
    d = label(role="dot", tone=tone, wrap=False)
    d.setFixedSize(10, 10)
    return d


def button(text, fn, role="", tip=""):
    b = QPushButton(text)
    if role:
        b.setProperty("role", role)
    if tip:
        b.setToolTip(tip)
    b.setCursor(Qt.CursorShape.PointingHandCursor)
    b.clicked.connect(lambda _c=False: fn())
    return b


def padded(*widgets):
    box = QWidget()
    lay = QVBoxLayout(box)
    lay.setContentsMargins(TOKENS["s4"], TOKENS["s3"], TOKENS["s4"], TOKENS["s3"])
    lay.setSpacing(TOKENS["s1"])
    for w in widgets:
        lay.addWidget(w)
    return box


def centered(widget):
    # Ai - one column, never wider than it needs, in the middle of the window
    widget.setMaximumWidth(TOKENS["column"])
    box = QWidget()
    lay = QHBoxLayout(box)
    lay.setContentsMargins(0, 0, 0, 0)
    lay.addStretch(1)
    lay.addWidget(widget, 100)
    lay.addStretch(1)
    return box


def clear(layout):
    while layout.count():
        item = layout.takeAt(0)
        if item.widget() is not None:
            # Ai - hidden at once, so the old screen never shows under the new one
            item.widget().hide()
            item.widget().deleteLater()
        elif item.layout() is not None:
            clear(item.layout())


def when(day):
    # Ai - a date the way you would say it
    try:
        d = date.fromisoformat(day)
    except ValueError:
        return day
    n = (date.today() - d).days
    if n <= 0:
        return "Today"
    if n == 1:
        return "Yesterday"
    if n < 7:
        return f"{n} days ago"
    return f"{d.day} {d:%b}" + ("" if d.year == date.today().year else f" {d.year}")


def age(day):
    try:
        n = (date.today() - date.fromisoformat(day)).days
    except ValueError:
        return "older"
    return "week" if n < 7 else "month" if n < 31 else "older"


class Row(QFrame):
    # Ai - one line in a card: a title, one quiet line under it, a count,
    #      and an arrow when it opens something. Click it, or Enter on it
    clicked = pyqtSignal()

    def __init__(self, title, meta="", tone="", count="", arrow=True, role="row", trole=""):
        super().__init__()
        self.setProperty("role", role)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setAttribute(Qt.WidgetAttribute.WA_Hover)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setMinimumHeight(TOKENS["hit"] if role in ("more", "addrow") else TOKENS["row"])
        lay = QHBoxLayout(self)
        lay.setContentsMargins(TOKENS["s3"], TOKENS["s1"], TOKENS["s3"], TOKENS["s1"])
        lay.setSpacing(TOKENS["s3"])
        if tone:
            lay.addWidget(dot(tone), alignment=Qt.AlignmentFlag.AlignVCenter)
        text = QVBoxLayout()
        text.setSpacing(2)
        text.addWidget(label(title, trole or ("link" if role in ("more", "addrow") else "")))
        if meta:
            text.addWidget(label(meta, "meta"))
        lay.addLayout(text, 1)
        if count != "":
            lay.addWidget(label(str(count), "count", wrap=False))
        self.chev = label("›" if arrow else "", "chev", wrap=False)
        self.chev.setVisible(arrow)
        lay.addWidget(self.chev)
        for w in self.findChildren(QLabel):
            w.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def mouseReleaseEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton and self.rect().contains(e.position().toPoint()):
            self.clicked.emit()

    def keyPressEvent(self, e):
        if e.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Space):
            self.clicked.emit()
        else:
            super().keyPressEvent(e)


class Card(QFrame):
    # Ai - a rounded box. With a key its heading folds it and it stays the
    #      way you left it, without one it is always open
    toggled = pyqtSignal(bool)

    def __init__(self, name="", key="", settings=None, tone="", count="", open_=True):
        super().__init__()
        self.setProperty("role", "card")
        self.key, self.settings = key, settings
        lay = QVBoxLayout(self)
        lay.setContentsMargins(TOKENS["s1"], TOKENS["s1"], TOKENS["s1"], TOKENS["s1"])
        lay.setSpacing(0)
        self.is_open = True
        if name:
            self.head = Row(name, tone=tone, count=count, arrow=bool(key), role="cardh", trole="cardt")
            self.head.setMinimumHeight(TOKENS["hit"] + TOKENS["s2"])
            lay.addWidget(self.head)
            if key:
                self.head.clicked.connect(self.toggle)
                self.head.setToolTip("Click to fold or open")
            else:
                self.head.setFocusPolicy(Qt.FocusPolicy.NoFocus)
                self.head.setCursor(Qt.CursorShape.ArrowCursor)
                self.head.setAttribute(Qt.WidgetAttribute.WA_Hover, False)
        self.body = QWidget()
        self.rows = QVBoxLayout(self.body)
        self.rows.setContentsMargins(0, 0, 0, 0)
        self.rows.setSpacing(0)
        lay.addWidget(self.body)
        if name and key:
            self.set_open(settings.value(f"open/{key}", open_, type=bool))

    def set_open(self, on):
        self.is_open = on
        self.body.setVisible(on)
        self.head.chev.setText("▾" if on else "▸")

    def toggle(self):
        self.set_open(not self.is_open)
        self.settings.setValue(f"open/{self.key}", self.is_open)
        self.toggled.emit(self.is_open)

    def add(self, widget):
        if self.rows.count():
            line = QFrame()
            line.setProperty("role", "line")
            line.setFixedHeight(1)
            self.rows.addWidget(line)
        self.rows.addWidget(widget)


class Palette(QDialog):
    # Ai - Ctrl+K, one search box for every project, item and action, the
    #      fast way for when you know what you want

    def __init__(self, parent, choices):
        super().__init__(parent)
        self.setWindowTitle("Search")
        self.resize(600, 440)
        self.choices = choices
        self.chosen = None
        self.box = QLineEdit(placeholderText="Type to find a project, a problem, a change, a note or an action")
        self.list = QListWidget()
        lay = QVBoxLayout(self)
        lay.setContentsMargins(TOKENS["s4"], TOKENS["s4"], TOKENS["s4"], TOKENS["s4"])
        lay.setSpacing(TOKENS["s3"])
        lay.addWidget(self.box)
        lay.addWidget(self.list)
        self.box.textChanged.connect(self.fill)
        self.box.returnPressed.connect(self.pick)
        self.list.itemActivated.connect(lambda _i: self.pick())
        self.fill("")

    def fill(self, text):
        words = text.lower().split()
        self.list.clear()
        for name, kind, action in self.choices:
            if all(w in f"{name} {kind}".lower() for w in words):
                it = QListWidgetItem(f"{name}      ·  {kind}")
                it.setData(Qt.ItemDataRole.UserRole, action)
                self.list.addItem(it)
                if self.list.count() >= 200:
                    break
        self.list.setCurrentRow(0)

    def keyPressEvent(self, e):
        if e.key() in (Qt.Key.Key_Down, Qt.Key.Key_Up):
            self.list.keyPressEvent(e)
        else:
            super().keyPressEvent(e)

    def pick(self):
        it = self.list.currentItem()
        if it is not None:
            self.chosen = it.data(Qt.ItemDataRole.UserRole)
            self.accept()


class Fold(QWidget):
    # Ai - a heading with an arrow inside the project form, the body is
    #      hidden until clicked, and stays the way you left it

    def __init__(self, name, settings):
        super().__init__()
        self.name, self.settings = name, settings
        self.head = QToolButton()
        self.head.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.head.setCheckable(True)
        self.head.toggled.connect(self.toggle)
        self.body = QWidget()
        self.inner = QVBoxLayout(self.body)
        self.inner.setContentsMargins(TOKENS["s5"], 0, 0, 0)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.head, alignment=Qt.AlignmentFlag.AlignLeft)
        lay.addWidget(self.body)
        self.head.setText(name)
        self.head.setChecked(settings.value(f"open/{name}", False, type=bool))
        self.toggle(self.head.isChecked())

    def toggle(self, on):
        self.head.setArrowType(Qt.ArrowType.DownArrow if on else Qt.ArrowType.RightArrow)
        self.body.setVisible(on)
        self.settings.setValue(f"open/{self.name}", on)


class ProjectDialog(QDialog):
    # Ai - the only form in the app, the essentials first, the rest folded

    def __init__(self, parent, project, settings):
        super().__init__(parent)
        self.setWindowTitle("Project")
        self.project = dict(project)
        self.name = QLineEdit(project["name"])
        self.repo = QLineEdit(project["repo"])
        self.repo.editingFinished.connect(self.fill_refs)
        pick = QPushButton("Choose…")
        pick.clicked.connect(self.choose)
        row = QHBoxLayout()
        row.addWidget(self.repo, 1)
        row.addWidget(pick)
        top = QFormLayout()
        top.addRow("Name", self.name)
        top.addRow("Folder", row)

        more = Fold("More settings", settings)
        self.ref = QComboBox(editable=True)
        self.base = QComboBox(editable=True)
        self.fill_refs()
        self.ref.setCurrentText(project.get("ref", ""))
        self.base.setCurrentText(project.get("base", ""))
        self.ref.setToolTip("The branch to follow. Empty follows whatever is checked out.")
        self.base.setToolTip("List only what changed since this branch. Empty lists everything.")
        self.paths = QLineEdit(" ".join(project.get("paths", [])))
        self.paths.setPlaceholderText("empty means the whole folder")
        self.problems = QLineEdit(project.get("problems", ""))
        self.problems.setPlaceholderText("for example docs/problems.toml")
        self.checks = QCheckBox("Check for unsaved, unshared and secret-looking files")
        self.checks.setChecked(project.get("git_checks", True))
        form = QFormLayout()
        form.addRow("Follow", self.ref)
        form.addRow("Changes since", self.base)
        form.addRow("Only these paths", self.paths)
        form.addRow("Problems file", self.problems)
        form.addRow("", self.checks)
        more.inner.addLayout(form)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(TOKENS["s4"], TOKENS["s4"], TOKENS["s4"], TOKENS["s4"])
        lay.setSpacing(TOKENS["s3"])
        lay.addLayout(top)
        lay.addWidget(more)
        lay.addWidget(buttons)
        self.resize(580, 0)

    def fill_refs(self):
        names = [""] + (refs(self.repo.text()) if is_repo(self.repo.text()) else [])
        for box in (self.ref, self.base):
            cur = box.currentText()
            box.clear()
            box.addItems(names)
            box.setCurrentText(cur)

    def choose(self):
        d = QFileDialog.getExistingDirectory(self, "Choose the project folder",
                                             self.repo.text() or str(Path.home()))
        if d:
            self.repo.setText(d)
            if not self.name.text().strip():
                self.name.setText(Path(d).name)
            self.fill_refs()

    def save(self):
        repo = self.repo.text().strip()
        if not repo or not Path(repo).is_dir():
            QMessageBox.warning(self, "Project", "Choose a folder that exists.")
            return
        if not is_repo(repo):
            # Ai - any code can be a project, a plain folder starts tracking here
            ok = QMessageBox.question(
                self, "Start tracking this folder?",
                "This folder is not tracked by git yet, so there are no changes to show.\n\n"
                "Start tracking it? This adds a hidden .git folder and changes no files.")
            if ok != QMessageBox.StandardButton.Yes:
                return
            subprocess.run(["git", "-C", repo, "init", "-q"], capture_output=True)
        self.project.update({
            "name": self.name.text().strip() or Path(repo).name,
            "repo": repo,
            "ref": self.ref.currentText().strip(),
            "base": self.base.currentText().strip(),
            "paths": self.paths.text().split(),
            "problems": self.problems.text().strip(),
            "git_checks": self.checks.isChecked(),
        })
        self.accept()


#    Window

# Ai - one screen at a time, like Manager:
#        home   every project, a dot says if something is wrong
#        list   one project, one of its three views
#        item   one problem or change, the plain words first
#      Back, Escape or Alt+Left always goes one step up

TABS = ["Problems", "Changes", "Notes"]

HINTS = {
    "home": "Pick a project to open it. A <b>red dot</b> means something is wrong right now.",
    "problems": "What is wrong, worst first. <b>Fine</b> stays folded until you open it.",
    "changes": "What changed, newest first. Open one to read what it means for you.",
    "notes": "Every note you wrote. <b>Copy notes for Claude</b> puts them all on the clipboard.",
}


class Window(QMainWindow):

    def __init__(self):
        super().__init__()
        self.settings = QSettings("rebuild", "changes")
        self.setWindowTitle("Changes")
        self.resize(self.settings.value("size", None) or QSize(760, 860))
        self.pool = QThreadPool.globalInstance()
        self.jobs = []
        self.projects = load_projects()
        self.project = None
        self.notes = {}
        self.rows = {}
        self.data = {}
        self.refsel = {}
        self.current = None
        self.trail = []
        self.screen = "home"
        self.tab = self.settings.value("tab", 0, type=int)
        self.shown = {}
        self.scroll_at = {}
        self.pending = None
        self.compare = None
        self.diff_args = []
        self.note = self.note_box = self.note_btn = self.diff = None

        self.save_timer = QTimer(self, singleShot=True, interval=600)
        self.save_timer.timeout.connect(self.save_now)

        # Ai - the header: back, where you are, search and more

        self.back = button("", self.go_back, "flat", "Back one step. Escape")
        self.htitle = label("", "title")
        self.hsub = label("", "sub")
        search = button("Search", self.open_palette, "flat", "Find any project, problem, change or action. Ctrl+K")
        self.more_btn = button("More", self.show_menu, "flat", "Everything else you can do here")
        top = QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        top.addWidget(self.back)
        top.addStretch()
        top.addWidget(search)
        top.addWidget(self.more_btn)

        self.seg = QFrame()
        self.seg.setProperty("role", "seg")
        sl = QHBoxLayout(self.seg)
        sl.setContentsMargins(2, 2, 2, 2)
        sl.setSpacing(2)
        self.segs = []
        for i, name in enumerate(TABS):
            b = button(name, lambda i=i: self.set_tab(i), "segb", f"Ctrl+{i + 1}")
            b.setCheckable(True)
            sl.addWidget(b, 1)
            self.segs.append(b)

        header = QWidget()
        hv = QVBoxLayout(header)
        hv.setContentsMargins(TOKENS["s1"], TOKENS["s2"], TOKENS["s1"], TOKENS["s2"])
        hv.setSpacing(TOKENS["s1"])
        hv.addLayout(top)
        hv.addWidget(self.htitle)
        hv.addWidget(self.hsub)
        hv.addSpacing(TOKENS["s2"])
        hv.addWidget(self.seg)

        # Ai - the page: one column of cards

        self.column = QWidget()
        self.column.setFocusPolicy(Qt.FocusPolicy.ClickFocus)
        self.col = QVBoxLayout(self.column)
        self.col.setContentsMargins(0, 0, 0, TOKENS["s6"])
        self.col.setSpacing(TOKENS["s3"])
        canvas = centered(self.column)
        canvas.setObjectName("canvas")
        self.scroll = QScrollArea(widgetResizable=True)
        self.scroll.setObjectName("page")
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setWidget(canvas)

        root = QWidget()
        r = QVBoxLayout(root)
        r.setContentsMargins(TOKENS["s4"], TOKENS["s2"], TOKENS["s4"], 0)
        r.setSpacing(0)
        r.addWidget(centered(header))
        r.addWidget(self.scroll, 1)
        self.setCentralWidget(root)

        # Ai - short messages show for a moment at the bottom, then go
        self.toast_label = QLabel(root)
        self.toast_label.setObjectName("toast")
        self.toast_label.hide()
        self.toast_timer = QTimer(self, singleShot=True, interval=TOKENS["toast_ms"])
        self.toast_timer.timeout.connect(self.toast_label.hide)

        self.shortcuts = [
            ("Ctrl+K", "Search everything", self.open_palette),
            ("Ctrl+F", "Search everything", self.open_palette),
            ("Ctrl+1", "Problems", lambda: self.set_tab(0)),
            ("Ctrl+2", "Changes", lambda: self.set_tab(1)),
            ("Ctrl+3", "Notes", lambda: self.set_tab(2)),
            ("Escape", "Back one step", self.escape),
            ("Alt+Left", "Back one step", self.go_back),
            ("Alt+Up", "Previous project", lambda: self.step_project(-1)),
            ("Alt+Down", "Next project", lambda: self.step_project(1)),
            ("Ctrl+N", "Add a note", self.open_note),
            ("Ctrl+Shift+A", "Ask Claude about this", self.ask_claude),
            ("Ctrl+Shift+C", "Copy notes for Claude", self.copy_notes),
            ("F5", "Check again and fetch", self.check_again),
            ("F1", "These keys", self.show_keys),
        ]
        for key, _label, fn in self.shortcuts:
            QShortcut(QKeySequence(key), self, fn)

        for p in self.projects:
            self.reload(p, fetch_first=False, quiet=True)
        last = self.settings.value("project", "")
        ids = [p["id"] for p in self.projects]
        if self.settings.value("screen", "home") != "home" and last in ids:
            self.open_project(ids.index(last))
        else:
            self.render()
        # Ai - nothing is highlighted until you press Tab
        QTimer.singleShot(0, self.column.setFocus)

    # Ai - window

    def closeEvent(self, e):
        self.save_now()
        self.settings.setValue("size", self.size())
        self.settings.setValue("tab", self.tab)
        self.settings.setValue("screen", "home" if self.screen == "home" else "list")
        super().closeEvent(e)

    def save_now(self):
        if self.project is not None:
            save_notes(self.project, self.notes)

    def run(self, fn, then):
        job = Job(fn)
        job.signals.done.connect(lambda result: (self.jobs.remove(job), then(result)))
        self.jobs.append(job)
        self.pool.start(job)

    def toast(self, text):
        t = self.toast_label
        t.setText(text)
        t.adjustSize()
        root = self.centralWidget()
        t.move((root.width() - t.width()) // 2, root.height() - t.height() - TOKENS["s5"])
        t.raise_()
        t.show()
        self.toast_timer.start()

    def show_keys(self):
        keys = {}
        for k, name, _f in self.shortcuts:
            keys.setdefault(name, []).append(k)
        rows = "".join(f"<tr><td><b>{' or '.join(k)}</b>&nbsp;&nbsp;&nbsp;&nbsp;</td><td>{name}</td></tr>"
                       for name, k in keys.items())
        QMessageBox.information(self, "Keys", f"<table cellpadding='4'>{rows}</table>")

    def set_look(self, theme=None, large=None):
        if theme is not None:
            self.settings.setValue("theme", theme)
        if large is not None:
            self.settings.setValue("large", large)
        apply_theme(QApplication.instance(), self.settings.value("theme", "Slate"),
                    self.settings.value("large", False, type=bool))
        self.render()

    # Ai - tips: one at a time, on the first few days, then they fade away

    def tip_on(self, key):
        if self.settings.value(f"hint/{key}", False, type=bool):
            return False
        try:
            days = json.loads(self.settings.value(f"hintdays/{key}", "[]"))
        except (TypeError, ValueError):
            days = []
        today = date.today().isoformat()
        if today not in days:
            if len(days) >= TOKENS["tip_days"]:
                return False
            self.settings.setValue(f"hintdays/{key}", json.dumps(days + [today]))
        return True

    def coach(self, key):
        if not self.tip_on(key):
            return
        f = QFrame()
        f.setProperty("role", "coach")
        h = QHBoxLayout(f)
        h.setContentsMargins(TOKENS["s4"], TOKENS["s2"], TOKENS["s2"], TOKENS["s2"])
        h.addWidget(para(HINTS[key]), 1)
        x = button("✕", lambda: (self.settings.setValue(f"hint/{key}", True), f.hide()), "flat", "Hide this tip")
        x.setFixedSize(TOKENS["hit"], TOKENS["hit"])
        h.addWidget(x, alignment=Qt.AlignmentFlag.AlignTop)
        self.col.addWidget(f)

    def reset_hints(self):
        for key in HINTS:
            self.settings.remove(f"hint/{key}")
            self.settings.remove(f"hintdays/{key}")
        self.render()

    # Ai - moving around

    def place(self):
        if self.screen in ("home", "compare"):
            return self.screen
        if self.screen == "list" and self.project is not None:
            return f"list:{self.project['id']}:{self.tab}"
        return "item"

    def go(self, screen, key=None):
        self.scroll_at[self.place()] = self.scroll.verticalScrollBar().value()
        self.screen = screen
        if key is not None:
            self.current = key
        if screen != "item":
            self.trail = []
        self.render(self.scroll_at.get(self.place(), 0) if screen != "item" else 0)

    def go_back(self):
        if self.screen == "item" and self.trail:
            self.current = self.trail.pop()
            self.render(0)
        elif self.screen == "item":
            self.go("list")
        elif self.screen in ("list", "compare"):
            self.go("home")

    def escape(self):
        # Ai - the first Escape leaves the note you are typing, the next goes back
        if self.note is not None and self.note.hasFocus():
            self.column.setFocus()
        else:
            self.go_back()

    def set_tab(self, i):
        if self.project is None:
            return
        self.scroll_at[self.place()] = self.scroll.verticalScrollBar().value()
        self.tab = i
        self.settings.setValue("tab", i)
        self.screen = "list"
        self.trail = []
        self.render(self.scroll_at.get(self.place(), 0))

    def render(self, pos=None):
        bar = self.scroll.verticalScrollBar()
        pos = bar.value() if pos is None else pos
        self.note = self.note_box = self.note_btn = self.diff = None
        clear(self.col)
        if self.screen == "list" and self.project is None:
            self.screen = "home"
        {"home": self.render_home, "list": self.render_list, "item": self.render_item,
         "compare": self.render_compare}[self.screen]()
        self.col.addStretch()
        self.update_header()
        QTimer.singleShot(0, lambda: bar.setValue(pos))

    def update_header(self):
        home, item = self.screen == "home", self.screen == "item"
        self.back.setVisible(not home)
        self.back.setText("‹  Back" if self.trail else "‹  Projects" if self.screen in ("list", "compare") else f"‹  {TABS[self.tab]}")
        self.htitle.setVisible(not item)
        self.hsub.setVisible(not item)
        self.seg.setVisible(self.screen == "list")
        if self.screen == "compare":
            self.htitle.setText("From v1")
            d = self.compare
            n = len(d["items"]) if isinstance(d, dict) else 0
            self.hsub.setText("Reading the copy of v1…" if d is None else
                              "Could not read it" if not isinstance(d, dict) else
                              f"{n} thing{'s' if n != 1 else ''} v1 had that this PC lacks" if n else
                              "Nothing is missing")
            return
        if home:
            n = len(self.projects)
            on = sum(d.get("on", 0) for d in self.data.values())
            self.htitle.setText("Changes")
            self.hsub.setText(f"{n} project{'s' if n != 1 else ''}" +
                              (f"  ·  {on} wrong right now" if on else ""))
            return
        if self.project is None:
            return
        self.htitle.setText(self.project["name"])
        self.hsub.setText(self.summary(self.project))
        d = self.data.get(self.project["id"], {})
        counts = [d.get("on", 0), len(d.get("changes", [])), len(self.noted())]
        for i, b in enumerate(self.segs):
            b.setText(f"{TABS[i]}   {counts[i]}" if counts[i] else TABS[i])
            b.setChecked(i == self.tab)

    def empty(self, head, text="", btn=None, action=None):
        box = QWidget()
        v = QVBoxLayout(box)
        v.setContentsMargins(TOKENS["s4"], TOKENS["s6"], TOKENS["s4"], TOKENS["s5"])
        v.setSpacing(TOKENS["s3"])
        for t, role in ((head, "emptyh"), (text, "emptyp")):
            if t:
                lab = label(t, role)
                lab.setAlignment(Qt.AlignmentFlag.AlignCenter)
                v.addWidget(lab)
        if btn:
            v.addWidget(button(btn, action, "primary"), alignment=Qt.AlignmentFlag.AlignCenter)
        self.col.addWidget(box)

    def add_rows(self, card, key, items, make):
        # Ai - a few rows at a time, Show more adds the next ones
        n = self.shown.get(key, TOKENS["show"])
        if len(items) <= n + 1:
            n = len(items)
        for it in items[:n]:
            card.add(make(it))
        if len(items) > n:
            left = len(items) - n
            step = min(left, TOKENS["more"])
            more = Row(f"Show {step} more" + (f"   ·   {left} left" if left > step else ""), role="more", arrow=False)
            more.clicked.connect(lambda: (self.shown.__setitem__(key, n + TOKENS["more"]), self.render()))
            card.add(more)

    # Ai - home: every project

    def v1_card(self):
        card = Card()
        row = Row("From v1", "What the old install had that this PC does not, and a button to bring each over", "accent")
        row.clicked.connect(self.open_compare)
        card.add(row)
        return card

    def render_home(self):
        if not self.projects:
            if compare_available():
                self.col.addWidget(self.v1_card())
            self.empty("No projects yet", "A project is any folder with code in it.",
                       "Add your first project", self.add_project)
            return
        self.coach("home")
        if compare_available():
            self.col.addWidget(self.v1_card())
        card = Card("Projects")
        for i, p in enumerate(self.projects):
            d = self.data.get(p["id"])
            if d is None:
                tone, meta, n = "none", "Checking…", ""
            elif d.get("missing"):
                tone, meta, n = "warn", "The folder is missing", ""
            elif d["on"]:
                tone, meta, n = "bad", f"{d['on']} wrong right now", d["on"]
            else:
                tone, meta, n = "good", "Nothing wrong right now", ""
            row = Row(p["name"], meta, tone, n)
            row.setToolTip(f"{p['repo']}\nRight-click for more")
            row.clicked.connect(lambda i=i: self.open_project(i))
            row.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
            row.customContextMenuRequested.connect(lambda pos, p=p, row=row: self.project_menu(p, row.mapToGlobal(pos)))
            card.add(row)
        self.col.addWidget(card)
        add = Row("+   Add a project", "Any folder with code in it", role="addrow", arrow=False)
        add.clicked.connect(self.add_project)
        self.col.addWidget(add)

    # Ai - from v1: what the old install had, each with a button to bring it over

    def open_compare(self):
        self.go("compare")
        if self.compare is None or isinstance(self.compare, Exception):
            self.load_compare()

    def load_compare(self):
        self.compare = None
        self.render()
        self.run(compare_scan, self.compare_loaded)

    def compare_loaded(self, result):
        self.compare = result
        if self.screen == "compare":
            self.render()

    def render_compare(self):
        d = self.compare
        if d is None:
            self.empty("Reading the copy of v1…", "This takes a minute.")
            return
        if isinstance(d, Exception):
            self.empty("Could not read the copy of v1", str(d), "Try again", self.load_compare)
            return
        if not d["items"]:
            self.empty("Nothing is missing", "This PC has everything v1 had.")
        for kind, name in COMPARE_KINDS:
            group = [i for i in d["items"] if i["kind"] == kind]
            if not group:
                continue
            card = Card(name, f"compare/{kind}", self.settings, "warn", len(group), open_=kind == "package")
            self.add_rows(card, f"compare/{kind}", group, self.compare_row)
            self.col.addWidget(card)
        notes = []
        if d.get("managed"):
            notes.append(f"{d['managed']} file{'s' if d['managed'] != 1 else ''} this install writes itself "
                         "are left alone, v1's version would undo what v2 set on purpose.")
        if d.get("unreadable"):
            notes.append(f"{d['unreadable']} file{'s' if d['unreadable'] != 1 else ''} only root can read "
                         "were not checked. rebuild compare in a terminal checks them too.")
        for n in notes:
            self.col.addWidget(label(n, "meta"))
        self.col.addWidget(button("Done, delete the copy of v1", self.forget_old, "",
                                  "Asks you to type delete first, in a terminal"))

    def compare_row(self, item):
        meta = item["why"] + (f"  ·  needs {item['waits_for']} first" if item.get("waits_for") else "")
        row = Row(item["title"], meta, arrow=False)
        btn = button("Bring over", lambda: self.bring_over([item["id"]]), "flat",
                     "Opens a terminal, it asks for your password")
        btn.setEnabled(not item.get("waits_for"))
        row.layout().addWidget(btn)
        return row

    def bring_over(self, ids):
        self.toast("A terminal opens, it asks for your password")

        def work():
            in_terminal("rebuild compare bring " + " ".join(shlex.quote(i) for i in ids))
            return compare_scan()

        self.compare = None
        self.render()
        self.run(work, self.compare_loaded)

    def forget_old(self):
        def work():
            in_terminal("rebuild compare delete")
            return None if not compare_available() else compare_scan()

        def done(result):
            if not compare_available():
                self.compare = None
                self.go("home")
                self.toast("The copy of v1 is gone")
            else:
                self.compare_loaded(result)

        self.toast("A terminal opens, type delete there to go ahead")
        self.run(work, done)

    # Ai - list: one view of one project

    def render_list(self):
        d = self.data.get(self.project["id"])
        if d is None:
            self.empty("Checking…", "This takes a few seconds.")
            return
        if d.get("missing"):
            self.empty("The folder is missing", f"{self.project['repo']} is not there, or is not tracked by git.",
                       "Project settings", self.edit_project)
            return
        self.coach(["problems", "changes", "notes"][self.tab])
        [self.list_problems, self.list_changes, self.list_notes][self.tab](d)

    def list_problems(self, d):
        # Ai - one card per state, worst first, only the worst is open
        if not d["problems"]:
            self.empty("No problems are listed yet", "Claude can write a problems file for this project.",
                       "Copy the request for Claude", lambda: self.copy_out(PROBLEMS_STYLE, "Request copied"))
            return
        groups = {s: [] for s in ORDER}
        for p in d["problems"]:
            groups[d["results"][p["id"]][0]].append(p)
        if not (groups["on"] or groups["design"] or groups["unknown"]):
            self.empty("Nothing is wrong right now", "Every check came back fine.")
        first = True
        for s in ORDER:
            if not groups[s]:
                continue
            card = Card(STATES[s], f"problems/{s}", self.settings, STATE_TONE[s], len(groups[s]),
                        open_=s == "on" or (first and s != "clear"))
            first = False
            self.add_rows(card, f"{self.project['id']}/problems/{s}", groups[s], self.problem_row)
            self.col.addWidget(card)

    def problem_row(self, p):
        key = f"problem:{p['id']}"
        bits = [p.get("area", ""), "you would not notice it" if p.get("quiet") else "",
                "✎ note" if self.has_note(key) else ""]
        row = Row(p["title"], "  ·  ".join(b for b in bits if b))
        row.clicked.connect(lambda: self.open_item(key))
        return row

    def list_changes(self, d):
        # Ai - newest first, grouped by how long ago, older ones folded
        if not d["changes"]:
            self.empty("No changes yet", "Changes show up here after the first commit.")
            return
        base = self.project.get("base")
        key = f"compare:{base}..{d['ref']}"
        if key in self.rows:
            card = Card()
            row = Row(f"Everything since {base}", "Every change below, added together", "accent")
            row.clicked.connect(lambda: self.open_item(key))
            card.add(row)
            self.col.addWidget(card)
        groups = {"week": [], "month": [], "older": []}
        for r in d["changes"]:
            groups[age(r["date"])].append(r)
        first = True
        for g, name in (("week", "Last 7 days"), ("month", "Last 30 days"), ("older", "Older")):
            if not groups[g]:
                continue
            card = Card(name, f"changes/{g}", self.settings, count=len(groups[g]), open_=first)
            first = False
            self.add_rows(card, f"{self.project['id']}/changes/{g}", groups[g], self.change_row)
            self.col.addWidget(card)

    def change_row(self, r):
        bits = [when(r["date"]), "✎ note" if self.has_note(r["hash"]) else ""]
        row = Row(r["subject"], "  ·  ".join(b for b in bits if b))
        row.clicked.connect(lambda: self.open_item(r["hash"]))
        return row

    def list_notes(self, d):
        keys = self.noted()
        if not keys:
            self.empty("No notes yet", "Open any problem or change and press Add a note.")
            return
        card = Card("Your notes", count=len(keys))

        def make(k):
            n = self.notes[k]
            first = n["text"].strip().splitlines()[0]
            kind = "Problem" if k.startswith("problem:") else "Change"
            row = Row(n["subject"], f"{kind}  ·  {first[:70]}{'…' if len(first) > 70 else ''}")
            row.clicked.connect(lambda: self.open_item(k))
            return row

        self.add_rows(card, f"{self.project['id']}/notes", keys, make)
        self.col.addWidget(card)
        self.col.addWidget(button(f"Copy {len(keys)} note{'s' if len(keys) != 1 else ''} for Claude",
                                  self.copy_notes, "primary", "Ready to paste into a Claude chat. Ctrl+Shift+C"))

    # Ai - item: one problem or change, what it means first, the rest folded

    def render_item(self):
        row = self.rows.get(self.current)
        if row is None:
            self.empty("This is not here any more", "It may have changed at the last check.",
                       "Back to the list", self.go_back)
            return
        self.col.addWidget(label(row["subject"], "title", select=True))
        if row["kind"] == "problem":
            self.item_problem(row["p"])
        else:
            self.item_change(row)

    def words(self, title, text, rich=False):
        card = Card()
        card.add(padded(label(title.upper(), "lab"), para(text) if rich else label(text, select=True)))
        self.col.addWidget(card)

    def item_problem(self, p):
        d = self.data[self.project["id"]]
        state, found = d["results"][p["id"]]
        quiet = "quiet, nothing on screen says so" if p.get("quiet") else "you would notice it"
        source = "built-in check" if p.get("source") == "git" else self.project.get("problems", "")
        self.col.addWidget(label(f"{p.get('area', '')}  ·  {quiet}  ·  {source}", "meta"))
        self.col.addWidget(label(STATES[state], "pill", STATE_TONE[state], wrap=False),
                           alignment=Qt.AlignmentFlag.AlignLeft)
        if p.get("means"):
            self.words("What it means for you", p["means"])
        if p.get("now") and state in ("on", "unknown"):
            self.words("What you can do now", p["now"])
        self.actions()
        parts = []
        if found:
            parts.append(f"<p><b>What the check found</b><br>{html.escape(found).replace(chr(10), '<br>')}</p>")
        if p.get("v2"):
            parts.append(f"<p><b>How it gets fixed</b><br>{html.escape(p['v2'])}</p>")
        fixes = d["fixed_by"].get(p["id"], [])
        if fixes:
            links = "<br>".join(f"<a href='change:{r['hash']}'>{html.escape(r['subject'])}</a>" for r in fixes)
            parts.append(f"<p><b>Fixed by</b><br>{links}</p>")
        if p.get("check"):
            parts.append("<p><b>How it is checked</b><br>A short read-only test, run as you:</p>"
                         f"<pre>{html.escape(p['check'].strip())}</pre>")
        if parts:
            self.details("".join(parts))

    def item_change(self, row):
        if "compare" in row:
            base, ref = row["compare"]
            self.col.addWidget(label(f"{base} against {ref}", "meta"))
            self.words("What it is", "Every file that differs, all the changes in the list added together.")
            self.diff_args = ["diff", base, ref]
            self.actions()
        else:
            f = parse(row["body"])
            bits = [when(row["date"]), row.get("author", "")] + ([f["Values"]] if "Values" in f else [])
            self.col.addWidget(label("  ·  ".join(b for b in bits if b), "meta"))
            if f.get("For you"):
                self.words("What it means for you", f["For you"])
            else:
                self.words("What it means for you", "<i>This change has no plain-words explanation. "
                           "Press Ask Claude to get one.</i>", rich=True)
            self.diff_args = ["show", "--format=", row["hash"]]
            self.actions()
            titles = {p["id"]: p["title"] for p in self.data[self.project["id"]]["problems"]}
            self.details(details_html(f, titles))
        files = numstat(self.project, self.diff_args)
        card = Card("Files and lines", "item/lines", self.settings, count=len(files), open_=False)
        self.diff = QTextEdit(readOnly=True)
        self.diff.setObjectName("diff")
        self.diff.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.diff.setMinimumHeight(420)
        card.add(padded(para(file_html(files)), self.diff))
        card.toggled.connect(self.load_diff)
        self.col.addWidget(card)
        self.load_diff(card.is_open)

    def details(self, text):
        card = Card("Details", "item/details", self.settings, open_=False)
        body = para(text)
        body.linkActivated.connect(self.follow)
        card.add(padded(body))
        self.col.addWidget(card)

    def actions(self):
        # Ai - the two things you can do, then your note, if there is one
        bar = QHBoxLayout()
        bar.setSpacing(TOKENS["s2"])
        bar.addWidget(button("Ask Claude", self.ask_claude, "primary",
                             "Copies a question with everything Claude needs to answer it. Ctrl+Shift+A"))
        self.note_btn = button("Add a note", self.open_note, "", "Ctrl+N")
        bar.addWidget(self.note_btn)
        bar.addStretch()
        self.col.addLayout(bar)
        text = self.notes.get(self.current, {}).get("text", "")
        self.note = QPlainTextEdit(placeholderText="Your note or question. Saved as you type, kept on this PC.")
        self.note.setPlainText(text)
        self.note.setFixedHeight(self.fontMetrics().height() * 7)
        self.note.textChanged.connect(self.note_changed)
        self.note_box = Card()
        self.note_box.add(padded(label("YOUR NOTE", "lab"), self.note))
        self.col.addWidget(self.note_box)
        self.show_note(bool(text.strip()))

    def load_diff(self, on):
        # Ai - read only when opened, a big change costs nothing until then
        if on and self.diff is not None and self.diff_args and not self.diff.toPlainText():
            self.diff.setHtml(diff_html(patch(self.project, self.diff_args)))

    def open_item(self, key):
        self.trail = []
        self.go("item", key)

    def follow(self, link):
        # Ai - every link inside the app: a problem, a change, a compare
        key = link.removeprefix("change:")
        if self.project is None or key not in self.rows:
            self.toast("That is not in this project any more")
            return
        if self.screen == "item" and self.current and self.current != key:
            self.trail.append(self.current)
            self.current = key
            self.render(0)
        else:
            # Ai - Back then goes to the list the item lives in
            self.tab = 0 if key.startswith("problem:") else 1
            self.open_item(key)

    # Ai - projects

    def open_project(self, i):
        self.save_now()
        self.project = self.projects[i]
        self.settings.setValue("project", self.project["id"])
        self.notes = load_notes(self.project)
        self.build_rows()
        self.go("list")
        self.reload(self.project, fetch_first=True, quiet=True)

    def step_project(self, d):
        if self.projects and self.project is not None and self.screen != "home":
            self.open_project((self.projects.index(self.project) + d) % len(self.projects))

    def add_project(self):
        dlg = ProjectDialog(self, new_project("", ""), self.settings)
        dlg.choose()
        if not dlg.repo.text():
            return
        if dlg.exec():
            self.projects.append(dlg.project)
            save_projects(self.projects)
            self.reload(dlg.project, fetch_first=False, quiet=True)
            self.open_project(len(self.projects) - 1)

    def edit_project(self, p=None):
        p = p or self.project
        if p is None:
            return
        dlg = ProjectDialog(self, p, self.settings)
        if dlg.exec():
            i = self.projects.index(p)
            self.projects[i] = dlg.project
            self.data.pop(dlg.project["id"], None)
            save_projects(self.projects)
            if self.project is p:
                self.project = dlg.project
                self.build_rows()
            self.render()
            self.reload(dlg.project, fetch_first=False)

    def project_menu(self, p, at):
        m = QMenu(self)
        m.addAction("Open", lambda: self.open_project(self.projects.index(p)))
        m.addAction("Project settings", lambda: self.edit_project(p))
        m.addAction("Open the folder", lambda: subprocess.Popen(["xdg-open", p["repo"]]))
        m.addSeparator()
        m.addAction("Remove from Changes", lambda: self.remove_project(p))
        m.exec(at)

    def remove_project(self, p=None):
        p = p or self.project
        if p is None:
            return
        ok = QMessageBox.question(self, "Remove project",
                                  f"Remove {p['name']} from Changes?\n\n"
                                  "Its folder and files are not touched, and your notes on it are kept.")
        if ok == QMessageBox.StandardButton.Yes:
            self.projects.remove(p)
            self.data.pop(p["id"], None)
            save_projects(self.projects)
            if self.project is p:
                self.project = None
            self.go("home")

    def show_menu(self):
        # Ai - everything that is not needed every time, out of sight until asked
        m = QMenu(self)
        if self.project is not None and self.screen != "home":
            m.addAction("Check again and fetch", self.check_again)
            names = refs(self.project["repo"]) if is_repo(self.project["repo"]) else []
            if len(names) > 1:
                pick = m.addMenu("Show changes from")
                now = self.data.get(self.project["id"], {}).get("ref") or ref_of(self.project)
                for name in names:
                    a = pick.addAction(name, lambda name=name: self.pick_ref(name))
                    a.setCheckable(True)
                    a.setChecked(name == now)
            m.addAction("Ask Claude for an overview", self.ask_overview)
            m.addAction("Copy notes for Claude", self.copy_notes).setEnabled(bool(self.noted()))
            c = m.addMenu("Copy for Claude to follow")
            c.addAction("How to write commits", lambda: self.copy_out(COMMIT_STYLE, "Commit style copied"))
            c.addAction("A problems file for this project", lambda: self.copy_out(PROBLEMS_STYLE, "Request copied"))
            m.addSeparator()
            m.addAction("Project settings", self.edit_project)
            m.addAction("Open the folder", lambda: subprocess.Popen(["xdg-open", self.project["repo"]]))
            m.addAction("Remove from Changes", self.remove_project)
        else:
            m.addAction("Add a project", self.add_project)
            m.addAction("Check every project again", self.check_again)
            if compare_available():
                m.addAction("What v1 had that this PC lacks", self.open_compare)
        m.addSeparator()
        look = m.addMenu("Look")
        theme = self.settings.value("theme", "Slate")
        for name in THEMES:
            a = look.addAction(name, lambda name=name: self.set_look(theme=name))
            a.setCheckable(True)
            a.setChecked(name == theme)
        look.addSeparator()
        large = look.addAction("Larger text")
        large.setCheckable(True)
        large.setChecked(self.settings.value("large", False, type=bool))
        large.toggled.connect(lambda on: self.set_look(large=on))
        m.addAction("Show the tips again", self.reset_hints)
        m.addAction("Keyboard shortcuts", self.show_keys)
        m.exec(self.more_btn.mapToGlobal(self.more_btn.rect().bottomLeft()))

    def pick_ref(self, name):
        self.refsel[self.project["id"]] = name
        self.reload(self.project, fetch_first=False)

    # Ai - loading, off screen

    def check_again(self):
        if self.project is not None and self.screen != "home":
            self.reload(self.project, fetch_first=True)
        else:
            for p in self.projects:
                self.reload(p, fetch_first=True, quiet=True)
            self.toast("Checking every project…")

    def build_rows(self):
        d = self.data.get(self.project["id"], {}) if self.project else {}
        rows = {}
        for p in d.get("problems", []):
            rows[f"problem:{p['id']}"] = {"kind": "problem", "p": p, "subject": p["title"], "date": "",
                                          "body": f"{p.get('means', '')} {p.get('area', '')}"}
        for r in d.get("changes", []):
            rows[r["hash"]] = r
        base = self.project.get("base") if self.project else ""
        if base and d.get("changes") and base != d.get("ref"):
            key = f"compare:{base}..{d['ref']}"
            rows[key] = {"kind": "change", "hash": key, "date": "", "subject": f"Everything since {base}",
                         "body": "", "compare": (base, d["ref"])}
        self.rows = rows

    def reload(self, project, fetch_first, quiet=False):
        ref = self.refsel.get(project["id"]) or ref_of(project)
        if not quiet:
            self.toast("Fetching and checking…" if fetch_first else "Checking…")

        def work():
            if not is_repo(project["repo"]):
                return {"missing": True}
            if fetch_first:
                fetch(project["repo"])
            problems, results = check_project(project)
            return {"problems": problems, "results": results, "changes": entries(project, ref),
                    "fixed_by": fixed_by(project, problems), "ref": ref,
                    "on": sum(1 for p in problems if results[p["id"]][0] == "on")}

        def done(data):
            if isinstance(data, Exception):
                self.toast(f"Something went wrong while checking: {data}")
                return
            if project not in self.projects:
                return
            old = self.data.get(project["id"])
            self.data[project["id"]] = data
            same = old and old.get("results") == data.get("results") and \
                [r["hash"] for r in old.get("changes", [])] == [r["hash"] for r in data.get("changes", [])]
            if fetch_first:
                write_summary([(p, d["problems"], d["results"]) for p in self.projects
                               for d in [self.data.get(p["id"])] if d and "problems" in d])
            if self.screen == "home":
                self.render()
            elif self.project is project:
                self.build_rows()
                if self.screen == "list" and not same:
                    self.render()
                else:
                    self.update_header()
                self.open_pending()
            if not quiet:
                self.toast(self.summary(project))

        self.run(work, done)

    def summary(self, project):
        d = self.data.get(project["id"])
        if d is None:
            return "Checking…"
        if d.get("missing"):
            return "The folder is missing"
        on, n = d.get("on", 0), len(d.get("changes", []))
        parts = [f"{on} wrong right now" if on else "Nothing wrong right now",
                 f"{n} change{'s' if n != 1 else ''}"]
        if self.refsel.get(project["id"]):
            parts.append(f"from {d.get('ref')}")
        return "  ·  ".join(parts)

    # Ai - notes and Claude

    def has_note(self, key):
        return bool(self.notes.get(key, {}).get("text", "").strip())

    def show_note(self, on):
        if self.note_box is not None:
            self.note_box.setVisible(on)
            self.note_btn.setVisible(not on)

    def open_note(self):
        if self.screen == "item" and self.note is not None:
            self.show_note(True)
            self.note.setFocus()

    def note_changed(self):
        if self.current is None or self.note is None:
            return
        row = self.rows[self.current]
        text = self.note.toPlainText()
        if not text.strip():
            self.notes.pop(self.current, None)
        elif row["kind"] == "problem":
            p = row["p"]
            self.notes[self.current] = {"text": text, "subject": p["title"], "date": "",
                                        "what": p.get("means", ""),
                                        "state": STATES[self.data[self.project["id"]]["results"][p["id"]][0]]}
        else:
            self.notes[self.current] = {"text": text, "subject": row["subject"], "date": row.get("date", ""),
                                        "what": parse(row.get("body", "")).get("What", "")}
        self.save_timer.start()
        self.update_header()

    def noted(self):
        return [k for k in self.notes if self.notes[k].get("text", "").strip()]

    def copy_out(self, text, what):
        copy_text(text)
        self.toast(f"{what}. Paste it into a Claude chat.")

    def copy_notes(self):
        keys = self.noted()
        if not keys or self.project is None:
            if self.project is not None:
                self.toast("No notes yet in this project")
            return
        probs = [k for k in keys if k.startswith("problem:")]
        changes = sorted([k for k in keys if not k.startswith("problem:")],
                         key=lambda k: self.notes[k].get("date") or "", reverse=True)
        out = [f"My notes on my project {self.project['name']}. Answer each one plainly and briefly.", ""]
        for k in probs + changes:
            n = self.notes[k]
            if k.startswith("problem:"):
                out.append(f"Problem: {n['subject']} ({n.get('state', '')})")
                out.append(f"What it means: {n['what']}")
            else:
                ref = "all changes" if k.startswith("compare:") else k[:7]
                out.append(f"Change {ref} ({n['date'] or 'all'}): {n['subject']}")
                if n.get("what"):
                    out.append(f"What it does: {n['what']}")
            out.append(f"My note: {n['text'].strip()}")
            out.append("")
        self.copy_out("\n".join(out), f"{len(keys)} note{'s' if len(keys) != 1 else ''} copied")

    def ask_claude(self):
        if self.project is None:
            return
        if self.screen != "item" or self.current not in self.rows:
            self.ask_overview()
            return
        row = self.rows[self.current]
        note = self.notes.get(self.current, {}).get("text", "").strip()
        if row["kind"] == "problem":
            state, found = self.data[self.project["id"]]["results"][row["p"]["id"]]
            text = prompt_problem(self.project, row["p"], state, found, note)
        elif "compare" in row:
            base, ref = row["compare"]
            text = (f"Summarise in plain words what changed in my project {self.project['name']} "
                    f"between {base} and {ref}, grouped by what it means for me.\n\nChanges:\n"
                    + "\n".join(f"  {r['date']}  {r['subject']}"
                                for r in self.data[self.project["id"]]["changes"]))
        else:
            text = prompt_change(self.project, row, note)
        self.copy_out(text, "Question copied")

    def ask_overview(self):
        if self.project is None:
            return
        d = self.data.get(self.project["id"], {})
        self.copy_out(prompt_overview(self.project, d.get("problems", []), d.get("results", {})),
                      "Overview copied")

    # Ai - Ctrl+K

    def open_palette(self):
        choices = [(p["name"], "project", ("project", i)) for i, p in enumerate(self.projects)]
        if self.project is not None:
            d = self.data.get(self.project["id"], {})
            for p in d.get("problems", []):
                choices.append((p["title"], f"problem, {STATES[d['results'][p['id']][0]].lower()}",
                                ("follow", f"problem:{p['id']}")))
            for r in d.get("changes", []):
                choices.append((r["subject"], f"change, {r['date']}", ("follow", f"change:{r['hash']}")))
            for k in self.noted():
                choices.append((self.notes[k]["text"].strip().splitlines()[0][:80], "note", ("follow", k)))
        choices += [
            ("Ask Claude for an overview of this project", "action", ("call", self.ask_overview)),
            ("Copy notes for Claude", "action", ("call", self.copy_notes)),
            ("Copy how Claude should write commits", "action",
             ("call", lambda: self.copy_out(COMMIT_STYLE, "Commit style copied"))),
            ("Copy the request for a problems file", "action",
             ("call", lambda: self.copy_out(PROBLEMS_STYLE, "Request copied"))),
            ("Add a project", "action", ("call", self.add_project)),
        ]
        if compare_available():
            choices.append(("What v1 had that this PC lacks", "action", ("call", self.open_compare)))
        choices += [
            ("Project settings", "action", ("call", self.edit_project)),
            ("Check again and fetch", "action", ("call", self.check_again)),
            ("Show the tips again", "action", ("call", self.reset_hints)),
            ("Keyboard shortcuts", "action", ("call", self.show_keys)),
        ]
        dlg = Palette(self, choices)
        if dlg.exec() and dlg.chosen:
            kind, arg = dlg.chosen
            if kind == "project":
                self.open_project(arg)
            elif kind == "follow":
                self.trail = []
                self.screen = "list"
                self.follow(arg)
            else:
                arg()

    # Ai - deep links: changes open NAME[/ITEM]

    def open_link(self, link):
        name, _, item = link.partition("/")
        for i, p in enumerate(self.projects):
            if p["name"].lower() == name.lower() or p["id"] == name:
                self.open_project(i)
                self.pending = item or None
                self.open_pending()
                break
        self.raise_()
        self.activateWindow()

    def open_pending(self):
        if self.pending and self.project is not None and self.project["id"] in self.data:
            link, self.pending = self.pending, None
            self.follow(link)


#    Text

def details_html(f, titles):
    labels = {"What": "What it does", "Why": "Why"}
    out = "".join(f"<p><b>{lab}</b><br>{html.escape(f[k])}</p>" for k, lab in labels.items() if k in f)
    # Ai - each problem a change fixes is a link to that problem
    ids = [i for i in re.findall(r"[a-z0-9-]+", f.get("Problems", "")) if i in titles]
    if ids:
        links = "<br>".join(f"<a href='problem:{i}'>{html.escape(titles[i])}</a>" for i in ids)
        out += f"<p><b>Problems it fixes</b><br>{links}</p>"
    return out or "<i>No details were written for this change.</i>"


def file_html(rows):
    if not rows:
        return "<i>no files</i>"
    out = []
    for path, add, rem in rows[:60]:
        if "=>" in path:
            # Ai - git writes a move as dir{a => b}/file, said here in words
            m = re.match(r"^(.*)\{(.*) => (.*)\}(.*)$", path)
            a, b = (m.group(1) + m.group(2) + m.group(4), m.group(1) + m.group(3) + m.group(4)) \
                if m else path.split(" => ", 1)
            path = f"{a.replace('//', '/')}  →  {b.replace('//', '/')}"
            if add == "0" and rem == "0":
                out.append(f"{html.escape(path)} &nbsp; <i>moved</i>")
                continue
        if add == "-":
            n = "<i>binary</i>"
        else:
            n = (f"<span style='color:{T['ok']}'>+{add}</span> "
                 f"<span style='color:{T['danger']}'>−{rem}</span>")
        out.append(f"{html.escape(path)} &nbsp; {n}")
    if len(rows) > 60:
        out.append(f"<i>and {len(rows) - 60} more</i>")
    return "<br>".join(out)


def diff_html(text):
    # Ai - one bold heading per file, green added, red removed, git's own
    #      bookkeeping lines are left out
    out = []
    lines = text.splitlines()
    for line in lines[:TOKENS["diff_lines"]]:
        if line.startswith(("index ", "--- ", "+++ ", "similarity ", "new file", "deleted file")):
            continue
        e = html.escape(line) or "&nbsp;"
        if line.startswith("diff --git"):
            out.append(f"\n<b>{html.escape(line.split(' b/', 1)[-1])}</b>")
        elif line.startswith("rename "):
            out.append(f"<i>{e}</i>")
        elif line.startswith("+"):
            out.append(f"<span style='color:{T['ok']}'>{e}</span>")
        elif line.startswith("-"):
            out.append(f"<span style='color:{T['danger']}'>{e}</span>")
        elif line.startswith("@@"):
            out.append("<i>…</i>")
        else:
            out.append(e)
    if len(lines) > TOKENS["diff_lines"]:
        out.append(f"<i>cut at {TOKENS['diff_lines']} lines</i>")
    return "<pre>" + "\n".join(out).lstrip("\n") + "</pre>"


def copy_text(text):
    # Ai - wl-copy keeps it after the window closes, Qt's copy is the fallback
    if shutil.which("wl-copy"):
        subprocess.run(["wl-copy"], input=text, text=True)
    QGuiApplication.clipboard().setText(text)


#    Start

def float_window():
    # Ai - Hyprland tiles new windows, this one floats so it can be moved
    #      only when the focused window is this one, nothing else is touched
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or not shutil.which("hyprctl"):
        return
    r = subprocess.run(["hyprctl", "activewindow", "-j"], capture_output=True, text=True)
    try:
        win = json.loads(r.stdout)
    except ValueError:
        return
    if win.get("class") == "changes" and not win.get("floating"):
        subprocess.run(["hyprctl", "dispatch", "togglefloating"], capture_output=True)
        subprocess.run(["hyprctl", "dispatch", "centerwindow"], capture_output=True)


# Ai - the command itself is a small launcher that fetches the newest
#      changes.py every time it starts, so there is never an update to run
#      offline it opens the copy it fetched last time
LAUNCHER = """#!/bin/sh
# changes - opens the newest version from the repo, see scripts/changes.py
REPO="${REBUILD_REPO:-$HOME/rebuild}"
CACHE="$HOME/.cache/changes.py"
mkdir -p "$HOME/.cache"
git -C "$REPO" fetch -q origin v2 2> /dev/null
if git -C "$REPO" show origin/v2:scripts/changes.py > "$CACHE.new" 2> /dev/null; then
\tmv "$CACHE.new" "$CACHE"
else
\trm -f "$CACHE.new"
fi
exec python3 "$CACHE" "$@"
"""

# Ai - the hourly check and the terminal line, set up by the window itself
#      the first time it opens, so nothing has to be run by hand
UNIT = """[Unit]
Description=Check every project in Changes for problems

[Service]
Type=oneshot
ExecStart=/usr/local/bin/changes --check
"""

TIMER = """[Unit]
Description=Check every project in Changes for problems, hourly

[Timer]
OnStartupSec=2min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
"""

BASHRC_LINE = '[ -s "$HOME/.cache/changes/problems.txt" ] && cat "$HOME/.cache/changes/problems.txt"  # changes'


def ensure_hooks():
    units = Path.home() / ".config/systemd/user"
    service, timer = units / "changes-check.service", units / "changes-check.timer"
    try:
        current = service.read_text() + timer.read_text()
    except OSError:
        current = ""
    if current != UNIT + TIMER:
        units.mkdir(parents=True, exist_ok=True)
        service.write_text(UNIT)
        timer.write_text(TIMER)
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "--user", "enable", "--now", "changes-check.timer"], capture_output=True)
    rc = Path.home() / ".bashrc"
    try:
        text = rc.read_text()
    except OSError:
        text = ""
    if "# changes" not in text:
        with rc.open("a") as fh:
            fh.write(("" if text.endswith("\n") or not text else "\n") + BASHRC_LINE + "\n")


def install():
    ensure_hooks()
    apps = Path.home() / ".local/share/applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / "changes.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Changes\n"
        "Comment=Manage, learn and improve your projects\n"
        "Exec=changes\nIcon=document-open-recent\nTerminal=false\n"
        "StartupWMClass=changes\n")
    r = subprocess.run(["sudo", "tee", "/usr/local/bin/changes"], input=LAUNCHER,
                       text=True, stdout=subprocess.DEVNULL)
    if r.returncode == 0:
        subprocess.run(["sudo", "chmod", "755", "/usr/local/bin/changes"])
        print("Changes is in the app launcher, and updates itself every time it opens")
    else:
        print("could not write /usr/local/bin/changes", file=sys.stderr)
        sys.exit(1)


def hand_over(link):
    # Ai - one window only: a second start passes its link to the first and quits
    sock = QLocalSocket()
    sock.connectToServer(SOCKET)
    if not sock.waitForConnected(300):
        return False
    sock.write((link or " ").encode())
    sock.waitForBytesWritten(300)
    sock.disconnectFromServer()
    return True


def main():
    args = sys.argv[1:]
    if args == ["--install"]:
        install()
        return
    if args == ["--check"]:
        print(f"{check_all()} problem(s) wrong right now")
        return
    link = args[1] if len(args) == 2 and args[0] == "open" else ""

    app = QApplication(sys.argv)
    app.setApplicationName("changes")
    app.setDesktopFileName("changes")
    if hand_over(link):
        return
    ensure_hooks()
    look = QSettings("rebuild", "changes")
    apply_theme(app, look.value("theme", "Slate"), look.value("large", False, type=bool))

    w = Window()
    QLocalServer.removeServer(SOCKET)
    server = QLocalServer()
    server.listen(SOCKET)

    def incoming():
        conn = server.nextPendingConnection()
        conn.waitForReadyRead(300)
        got = bytes(conn.readAll()).decode().strip()
        conn.close()
        if got:
            w.open_link(got)
        w.raise_()
        w.activateWindow()

    server.newConnection.connect(incoming)
    w.show()
    if link:
        w.open_link(link)
    QTimer.singleShot(400, float_window)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

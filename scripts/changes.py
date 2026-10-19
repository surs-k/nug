#!/usr/bin/env python3

# Ai - changes
#      a calm place to manage, learn and improve your projects, any git repo
#      every project has three views, one at a time:
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
import shutil
import subprocess
import sys
import tomllib
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PyQt6.QtCore import QObject, QRunnable, QSettings, QSize, Qt, QThreadPool, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFontDatabase, QGuiApplication, QKeySequence, QPalette, QShortcut
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QFrame, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
    QMenu, QMessageBox, QPlainTextEdit, QPushButton, QScrollArea, QSplitter, QStackedWidget,
    QTabBar, QTextEdit, QToolButton, QVBoxLayout, QWidget,
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


#    Tokens

# Ai - every size and colour in one place, the rest comes from your theme
#      red, amber and green are the only fixed colours, and each always
#      means the same thing: wrong now, worth a look, fine
TOKENS = {
    "bad":   "#d0453b",
    "warn":  "#c8891a",
    "good":  "#2e9e5b",
    "gap":   8,
    "title": 1.5,
    "small": 0.9,
    "diff_lines": 4000,
    "ask_lines":  300,
    "log_limit":  500,
}


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


#    Parts

def scaled(widget, factor, bold=False):
    f = widget.font()
    f.setPointSizeF(f.pointSizeF() * factor)
    f.setBold(bold)
    widget.setFont(f)
    return widget


def muted(widget):
    # Ai - the theme's own quiet colour, so it fits light and dark
    pal = widget.palette()
    pal.setColor(QPalette.ColorRole.WindowText,
                 pal.color(QPalette.ColorGroup.Disabled, QPalette.ColorRole.WindowText))
    widget.setPalette(pal)
    return widget


def para(text=""):
    lab = QLabel(text)
    lab.setWordWrap(True)
    lab.setTextFormat(Qt.TextFormat.RichText)
    lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse
                                | Qt.TextInteractionFlag.LinksAccessibleByMouse)
    lab.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
    return lab


def bold(text):
    lab = QLabel(text)
    f = lab.font()
    f.setBold(True)
    lab.setFont(f)
    return lab


class Fold(QWidget):
    # Ai - a heading with an arrow, the arrow says it opens, the body is
    #      hidden until clicked, and stays the way you left it

    def __init__(self, name, settings):
        super().__init__()
        self.name, self.settings = name, settings
        self.head = QToolButton()
        self.head.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.head.setAutoRaise(True)
        self.head.setCheckable(True)
        self.head.toggled.connect(self.toggle)
        self.body = QWidget()
        self.inner = QVBoxLayout(self.body)
        self.inner.setContentsMargins(TOKENS["gap"] * 3, 0, 0, 0)
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


class Hint(QFrame):
    # Ai - a one-line tip that explains a view the first few times, then
    #      fades: Got it hides it for good, and it never blocks anything

    def __init__(self, key, text, settings):
        super().__init__()
        self.key, self.settings = key, settings
        self.setFrameShape(QFrame.Shape.StyledPanel)
        btn = QPushButton("Got it")
        btn.setFlat(True)
        btn.clicked.connect(self.dismiss)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(TOKENS["gap"], TOKENS["gap"] // 2, TOKENS["gap"], TOKENS["gap"] // 2)
        lay.addWidget(para(text), 1)
        lay.addWidget(btn, alignment=Qt.AlignmentFlag.AlignTop)

    def dismissed(self):
        return self.settings.value(f"hint/{self.key}", False, type=bool)

    def dismiss(self):
        self.settings.setValue(f"hint/{self.key}", True)
        self.hide()


class Palette(QDialog):
    # Ai - Ctrl+K, one search box for every project, item and action, the
    #      fast way for when you know what you want

    def __init__(self, parent, choices):
        super().__init__(parent)
        self.setWindowTitle("Go to")
        self.resize(600, 440)
        self.choices = choices
        self.chosen = None
        self.box = QLineEdit(placeholderText="Type to find a project, a problem, a change or an action")
        self.list = QListWidget()
        lay = QVBoxLayout(self)
        lay.addWidget(self.box)
        lay.addWidget(self.list)
        self.box.textChanged.connect(self.fill)
        self.box.returnPressed.connect(self.pick)
        self.list.itemActivated.connect(lambda _i: self.pick())
        self.fill("")

    def fill(self, text):
        words = text.lower().split()
        self.list.clear()
        for label, kind, action in self.choices:
            if all(w in f"{label} {kind}".lower() for w in words):
                it = QListWidgetItem(f"{label}      ·  {kind}")
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

class Window(QMainWindow):

    def __init__(self):
        super().__init__()
        self.settings = QSettings("rebuild", "changes")
        self.setWindowTitle("Changes")
        self.resize(self.settings.value("size", None) or QSize(1180, 720))
        self.pool = QThreadPool.globalInstance()
        self.jobs = []
        self.projects = load_projects()
        self.project = None
        self.notes = {}
        self.rows = {}
        self.data = {}
        self.current = None
        self.diff_args = []
        self.show_clear = False
        self.pending = None

        self.save_timer = QTimer(self, singleShot=True, interval=600)
        self.save_timer.timeout.connect(self.save_now)

        # Ai - column one: projects

        self.plist = QListWidget()
        self.plist.currentRowChanged.connect(self.pick_project)
        self.plist.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.plist.customContextMenuRequested.connect(self.project_menu)
        add = QPushButton("+  Add project")
        add.setToolTip("Any folder with code in it")
        add.clicked.connect(self.add_project)
        self.edit_btn = QPushButton("Project settings")
        self.edit_btn.setToolTip("Right-click a project for more")
        self.edit_btn.clicked.connect(self.edit_project)
        pcol = QWidget()
        pv = QVBoxLayout(pcol)
        pv.setContentsMargins(0, 0, 0, 0)
        pv.addWidget(muted(bold("Projects")))
        pv.addWidget(self.plist, 1)
        pv.addWidget(add)
        pv.addWidget(self.edit_btn)

        # Ai - column two: one view of the project

        self.tabs = QTabBar()
        for t in ("Problems", "Changes", "Notes"):
            self.tabs.addTab(t)
        self.tabs.setExpanding(False)
        self.version = QComboBox()
        self.version.setToolTip("Which branch's changes to show")
        self.version.activated.connect(lambda _i: self.reload(fetch_first=False))
        self.search = QLineEdit()
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self.filter)
        self.hints = [
            Hint("problems", "<b>Problems</b> lists what is wrong. <b>Wrong right now</b> comes first, "
                 "<b>Built in</b> is how it was made, and <b>Fine</b> is folded away.", self.settings),
            Hint("changes", "<b>Changes</b> lists what changed, newest first. Click one for what it means "
                 "for you. The code stays folded until you open it.", self.settings),
            Hint("notes", "<b>Notes</b> collects every note you wrote. "
                 "<b>Copy notes for Claude</b> puts them all on the clipboard.", self.settings),
        ]
        self.list = QListWidget()
        self.list.setWordWrap(True)
        self.list.setSpacing(3)
        self.list.currentItemChanged.connect(self.show_item)
        self.list.itemClicked.connect(self.clicked)

        mid = QWidget()
        mv = QVBoxLayout(mid)
        mv.setContentsMargins(0, 0, 0, 0)
        # Ai - the branch picker sits beside the tabs, shown only on Changes
        self.version.setMaximumWidth(140)
        self.tabs.setUsesScrollButtons(False)
        head = QHBoxLayout()
        head.addWidget(self.tabs)
        head.addStretch()
        head.addWidget(self.version)
        mv.addLayout(head)
        for h in self.hints:
            mv.addWidget(h)
        mv.addWidget(self.search)
        mv.addWidget(self.list, 1)

        # Ai - column three: one item

        self.title = scaled(para(), TOKENS["title"], bold=True)
        self.meta = muted(scaled(para(), TOKENS["small"]))
        self.state = para()
        self.foryou = para()
        self.now = para()
        self.details = Fold("Details", self.settings)
        self.details_text = para()
        self.details_text.linkActivated.connect(self.follow)
        self.details.inner.addWidget(self.details_text)
        self.lines = Fold("Files and lines", self.settings)
        self.filelist = para()
        self.diff = QTextEdit(readOnly=True)
        self.diff.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.diff.setMinimumHeight(360)
        self.lines.inner.addWidget(self.filelist)
        self.lines.inner.addWidget(self.diff)
        self.lines.head.toggled.connect(self.load_diff)

        self.ask = QPushButton("Ask Claude")
        self.ask.setToolTip("Copies a question with everything Claude needs to answer it. Ctrl+Shift+A")
        self.ask.clicked.connect(self.ask_claude)
        self.note_btn = QPushButton("Add a note")
        self.note_btn.setToolTip("Ctrl+N")
        self.note_btn.clicked.connect(self.open_note)
        actions = QHBoxLayout()
        actions.addWidget(self.ask)
        actions.addWidget(self.note_btn)
        actions.addStretch()
        self.note = QPlainTextEdit(placeholderText="Your note or question. Saved as you type, kept on this PC.")
        self.note.setFixedHeight(self.fontMetrics().height() * 6)
        self.note.textChanged.connect(self.note_changed)
        self.note_label = bold("Your note")

        detail = QWidget()
        d = QVBoxLayout(detail)
        d.setSpacing(TOKENS["gap"])
        d.addWidget(self.title)
        d.addWidget(self.meta)
        d.addWidget(self.state)
        d.addSpacing(TOKENS["gap"])
        d.addWidget(self.foryou)
        d.addWidget(self.now)
        d.addSpacing(TOKENS["gap"])
        d.addLayout(actions)
        d.addWidget(self.note_label)
        d.addWidget(self.note)
        d.addSpacing(TOKENS["gap"])
        d.addWidget(self.details)
        d.addWidget(self.lines)
        d.addStretch()

        scroll = QScrollArea(widgetResizable=True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(detail)

        # Ai - shown when nothing is picked, it always says what to do next
        self.empty = muted(para())
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_btn = QPushButton()
        self.empty_btn.clicked.connect(lambda: self.empty_action and self.empty_action())
        self.empty_action = None
        epage = QWidget()
        ev = QVBoxLayout(epage)
        ev.addStretch()
        ev.addWidget(self.empty)
        ev.addWidget(self.empty_btn, alignment=Qt.AlignmentFlag.AlignCenter)
        ev.addStretch()
        self.pages = QStackedWidget()
        self.pages.addWidget(epage)
        self.pages.addWidget(scroll)

        self.split = QSplitter()
        self.split.addWidget(pcol)
        self.split.addWidget(mid)
        self.split.addWidget(self.pages)
        self.split.setStretchFactor(2, 1)
        self.split.setSizes([180, 380, 620])
        saved = self.settings.value("split")
        if saved:
            self.split.restoreState(saved)

        # Ai - bottom bar: what is happening, and the one action that leaves

        self.status = muted(QLabel(""))
        keys = QPushButton("Keys")
        keys.setFlat(True)
        keys.setToolTip("Every keyboard shortcut. F1")
        keys.clicked.connect(self.show_keys)
        self.copy = QPushButton()
        self.copy.setToolTip("Every note in this project, ready to paste into a Claude chat. Ctrl+Shift+C")
        self.copy.clicked.connect(self.copy_notes)
        bar = QHBoxLayout()
        bar.addWidget(self.status, 1)
        bar.addWidget(keys)
        bar.addWidget(self.copy)

        root = QWidget()
        r = QVBoxLayout(root)
        r.addWidget(self.split, 1)
        r.addLayout(bar)
        self.setCentralWidget(root)

        self.shortcuts = [
            ("Ctrl+K", "Go to anything", self.open_palette),
            ("Ctrl+F", "Search this list", self.search.setFocus),
            ("Ctrl+1", "Problems", lambda: self.tabs.setCurrentIndex(0)),
            ("Ctrl+2", "Changes", lambda: self.tabs.setCurrentIndex(1)),
            ("Ctrl+3", "Notes", lambda: self.tabs.setCurrentIndex(2)),
            ("Alt+Up", "Previous project", lambda: self.step_project(-1)),
            ("Alt+Down", "Next project", lambda: self.step_project(1)),
            ("Ctrl+N", "Add a note", self.open_note),
            ("Ctrl+Shift+A", "Ask Claude about this", self.ask_claude),
            ("Ctrl+Shift+C", "Copy notes for Claude", self.copy_notes),
            ("F5", "Check again and fetch", lambda: self.reload(fetch_first=True)),
            ("Escape", "Back to the list", self.list.setFocus),
            ("F1", "These keys", self.show_keys),
        ]
        for key, _label, fn in self.shortcuts:
            QShortcut(QKeySequence(key), self, fn)

        self.tabs.setCurrentIndex(self.settings.value("tab", 0, type=int))
        self.tabs.currentChanged.connect(self.tab_changed)
        self.show_hint()
        self.fill_projects()

    # Ai - window

    def closeEvent(self, e):
        self.save_now()
        self.settings.setValue("size", self.size())
        self.settings.setValue("split", self.split.saveState())
        self.settings.setValue("tab", self.tabs.currentIndex())
        super().closeEvent(e)

    def save_now(self):
        if self.project is not None:
            save_notes(self.project, self.notes)

    def run(self, fn, then):
        job = Job(fn)
        job.signals.done.connect(lambda result: (self.jobs.remove(job), then(result)))
        self.jobs.append(job)
        self.pool.start(job)

    def say(self, text):
        self.status.setText(text)

    def show_keys(self):
        rows = "".join(f"<tr><td><b>{k}</b>&nbsp;&nbsp;&nbsp;&nbsp;</td><td>{l}</td></tr>"
                       for k, l, _f in self.shortcuts)
        QMessageBox.information(self, "Keys", f"<table>{rows}</table>")

    # Ai - projects

    def fill_projects(self):
        self.plist.blockSignals(True)
        self.plist.clear()
        for p in self.projects:
            it = QListWidgetItem(p["name"])
            it.setToolTip(p["repo"])
            self.plist.addItem(it)
        self.plist.blockSignals(False)
        self.edit_btn.setEnabled(bool(self.projects))
        self.project_badges()
        if not self.projects:
            self.project = None
            self.list.clear()
            self.empty_state("No projects yet. A project is any folder with code in it.",
                             "Add your first project", self.add_project)
            return
        last = self.settings.value("project", "")
        ids = [p["id"] for p in self.projects]
        self.plist.setCurrentRow(ids.index(last) if last in ids else 0)

    def project_badges(self):
        # Ai - the count of what is wrong right now, beside each name
        for i, p in enumerate(self.projects):
            it = self.plist.item(i)
            if it is None:
                continue
            n = self.data.get(p["id"], {}).get("on")
            it.setText(f"{p['name']}   {n}" if n else p["name"])
            it.setForeground(QColor(TOKENS["bad"]) if n else self.palette().color(QPalette.ColorRole.Text))

    def pick_project(self, row):
        if row < 0 or row >= len(self.projects):
            return
        self.save_now()
        self.project = self.projects[row]
        self.settings.setValue("project", self.project["id"])
        self.notes = load_notes(self.project)
        self.show_clear = False
        self.update_copy()
        self.version.blockSignals(True)
        self.version.clear()
        if is_repo(self.project["repo"]):
            names = refs(self.project["repo"])
            self.version.addItems(names)
            want = ref_of(self.project)
            if want == "HEAD":
                want = git(self.project["repo"], "rev-parse", "--abbrev-ref", "HEAD").strip()
            self.version.setCurrentText(want)
        self.version.blockSignals(False)
        self.fill()
        self.reload(fetch_first=False)
        self.reload(fetch_first=True, quiet=True)

    def step_project(self, d):
        if self.projects:
            self.plist.setCurrentRow((self.plist.currentRow() + d) % len(self.projects))

    def add_project(self):
        dlg = ProjectDialog(self, new_project("", ""), self.settings)
        dlg.choose()
        if not dlg.repo.text():
            return
        if dlg.exec():
            self.projects.append(dlg.project)
            save_projects(self.projects)
            self.fill_projects()
            self.plist.setCurrentRow(len(self.projects) - 1)

    def edit_project(self):
        if self.project is None:
            return
        dlg = ProjectDialog(self, self.project, self.settings)
        if dlg.exec():
            i = self.projects.index(self.project)
            self.projects[i] = dlg.project
            self.data.pop(dlg.project["id"], None)
            save_projects(self.projects)
            self.fill_projects()
            self.plist.setCurrentRow(i)

    def project_menu(self, pos):
        if self.project is None:
            return
        m = QMenu(self)
        m.addAction("Project settings", self.edit_project)
        m.addAction("Ask Claude for an overview", self.ask_overview)
        m.addAction("Open the folder", lambda: subprocess.Popen(["xdg-open", self.project["repo"]]))
        m.addSeparator()
        m.addAction("Remove from Changes", self.remove_project)
        m.exec(self.plist.mapToGlobal(pos))

    def remove_project(self):
        ok = QMessageBox.question(self, "Remove project",
                                  f"Remove {self.project['name']} from Changes?\n\n"
                                  "Its folder and files are not touched, and your notes on it are kept.")
        if ok == QMessageBox.StandardButton.Yes:
            self.projects.remove(self.project)
            save_projects(self.projects)
            self.project = None
            self.fill_projects()

    # Ai - loading, off screen

    def reload(self, fetch_first, quiet=False):
        if self.project is None:
            return
        project = self.project
        ref = self.version.currentText() or ref_of(project)
        if not quiet:
            self.say("Fetching and checking…" if fetch_first else "Checking…")

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
                self.say(f"Something went wrong while checking: {data}")
                return
            old = self.data.get(project["id"])
            self.data[project["id"]] = data
            self.project_badges()
            if self.project is not project:
                return
            same = old and old.get("results") == data.get("results") and \
                [r["hash"] for r in old.get("changes", [])] == [r["hash"] for r in data.get("changes", [])]
            if not same:
                keep = self.current
                self.fill()
                if keep:
                    self.select(keep)
            self.say(self.summary())
            if fetch_first:
                write_summary([(p, d["problems"], d["results"]) for p in self.projects
                               for d in [self.data.get(p["id"])] if d and "problems" in d])

        self.run(work, done)

    def summary(self):
        d = self.data.get(self.project["id"], {})
        if d.get("missing"):
            return "The project folder is missing"
        on, n = d.get("on", 0), len(d.get("changes", []))
        return f"{on} wrong right now   ·   {n} change{'s' if n != 1 else ''}"

    # Ai - the middle list

    def show_hint(self):
        for i, h in enumerate(self.hints):
            h.setVisible(i == self.tabs.currentIndex() and not h.dismissed())

    def tab_changed(self, i):
        self.settings.setValue("tab", i)
        self.show_hint()
        self.fill()

    def fill(self):
        self.list.clear()
        self.rows = {}
        self.current = None
        tab = self.tabs.currentIndex()
        self.version.setVisible(tab == 1 and self.version.count() > 1)
        self.search.setPlaceholderText(f"Search {['problems', 'changes', 'notes'][tab]}   Ctrl+F")
        if self.project is None:
            return
        d = self.data.get(self.project["id"])
        if d is None:
            self.empty_state("Checking…")
            return
        if d.get("missing"):
            self.empty_state(f"The folder {self.project['repo']} is not there, or is not tracked by git.",
                             "Project settings", self.edit_project)
            return
        [self.fill_problems, self.fill_changes, self.fill_notes][tab](d)
        self.filter(self.search.text())

    def empty_state(self, text, button=None, action=None):
        self.pages.setCurrentIndex(0)
        self.empty.setText(text.replace("\n", "<br>"))
        self.empty_action = action
        self.empty_btn.setText(button or "")
        self.empty_btn.setVisible(bool(button))

    def group(self, text, key):
        head = QListWidgetItem(text)
        f = head.font()
        f.setBold(True)
        head.setFont(f)
        head.setFlags(Qt.ItemFlag.ItemIsEnabled)
        head.setData(Qt.ItemDataRole.UserRole, key)
        self.list.addItem(head)

    def fill_problems(self, d):
        # Ai - grouped by state, worst first, what is fine is folded away
        groups = {s: [] for s in ORDER}
        for p in d["problems"]:
            groups[d["results"][p["id"]][0]].append(p)
        for s in ORDER:
            if not groups[s]:
                continue
            folded = s == "clear" and not self.show_clear
            arrow = ("  ▸" if folded else "  ▾") if s == "clear" else ""
            self.group(f"{STATES[s]}  ({len(groups[s])}){arrow}", f"group:{s}")
            for p in groups[s]:
                key = f"problem:{p['id']}"
                self.rows[key] = {"kind": "problem", "p": p, "subject": p["title"], "date": "",
                                  "body": f"{p.get('means', '')} {p.get('area', '')}"}
                self.add_item(key, folded)
        if not d["problems"]:
            self.empty_state("No problems are listed for this project yet.\n\n"
                             "Claude can write a problems file for it.",
                             "Copy the request for Claude", lambda: self.copy_out(PROBLEMS_STYLE, "Request copied"))
        elif not groups["on"] and not groups["design"] and not groups["unknown"]:
            self.empty_state("Nothing is wrong right now.")
        else:
            self.empty_state("Pick a problem on the left.")

    def fill_changes(self, d):
        for row in d["changes"]:
            self.rows[row["hash"]] = row
            self.add_item(row["hash"])
        base = self.project.get("base")
        if base and base != d["ref"] and d["changes"]:
            key = f"compare:{base}..{d['ref']}"
            self.rows[key] = {"kind": "change", "hash": key, "date": "", "subject": f"Everything since {base}",
                              "body": "", "compare": (base, d["ref"])}
            self.add_item(key)
        self.empty_state("Pick a change on the left." if d["changes"] else "No changes yet.")

    def fill_notes(self, d):
        # Ai - every noted item, whichever view it lives in
        keys = [k for k, n in self.notes.items() if n.get("text", "").strip()]
        for k in keys:
            n = self.notes[k]
            label = ("Problem: " if k.startswith("problem:") else "Change: ") + n["subject"]
            self.rows[f"note:{k}"] = {"kind": "note", "target": k, "subject": label,
                                      "date": n.get("date", ""), "body": n["text"]}
            self.add_item(f"note:{k}")
        if keys:
            self.empty_state("Click a note to go to what it is about.")
        else:
            self.empty_state("No notes yet.\n\nOpen any problem or change and press Add a note.")

    def label(self, key):
        row = self.rows[key]
        noted = row["kind"] != "note" and bool(self.notes.get(key, {}).get("text", "").strip())
        return row["subject"] + ("   ✎" if noted else "")

    def add_item(self, key, folded=False):
        it = QListWidgetItem(self.label(key))
        it.setData(Qt.ItemDataRole.UserRole, key)
        it.setData(Qt.ItemDataRole.UserRole + 1, folded)
        row = self.rows[key]
        if row["kind"] == "problem":
            it.setToolTip(row["p"].get("area", ""))
            if self.data[self.project["id"]]["results"][row["p"]["id"]][0] == "on":
                it.setForeground(QColor(TOKENS["bad"]))
        else:
            it.setToolTip(row.get("date") or "")
        self.list.addItem(it)

    def clicked(self, item):
        key = item.data(Qt.ItemDataRole.UserRole)
        if key == "group:clear":
            self.show_clear = not self.show_clear
            self.fill()
        elif key.startswith("note:"):
            self.follow(self.rows[key]["target"])

    def filter(self, text):
        t = text.lower().strip()
        for i in range(self.list.count()):
            it = self.list.item(i)
            key = it.data(Qt.ItemDataRole.UserRole)
            if key.startswith("group:"):
                it.setHidden(bool(t))
                continue
            row = self.rows[key]
            hay = f"{row['subject']} {row.get('body', '')}".lower()
            folded = bool(it.data(Qt.ItemDataRole.UserRole + 1)) and not t
            it.setHidden(folded or (bool(t) and t not in hay))

    def select(self, key):
        for i in range(self.list.count()):
            if self.list.item(i).data(Qt.ItemDataRole.UserRole) == key:
                self.list.setCurrentRow(i)
                return True
        return False

    def follow(self, link):
        # Ai - every link inside the app: a problem, a change, a compare
        self.search.clear()
        if link.startswith("problem:"):
            self.tabs.setCurrentIndex(0)
            if not self.select(link):
                self.show_clear = True
                self.fill()
                self.select(link)
        else:
            self.tabs.setCurrentIndex(1)
            self.select(link.removeprefix("change:"))

    # Ai - the right side

    def show_item(self, item, _old=None):
        if item is None:
            return
        key = item.data(Qt.ItemDataRole.UserRole)
        if key.startswith(("group:", "note:")):
            return
        row = self.rows[key]
        self.current = key
        self.pages.setCurrentIndex(1)
        self.title.setText(html.escape(row["subject"]))
        if row["kind"] == "problem":
            self.show_problem(row["p"])
        else:
            self.show_change(row)
        text = self.notes.get(key, {}).get("text", "")
        self.note.blockSignals(True)
        self.note.setPlainText(text)
        self.note.blockSignals(False)
        self.show_note(bool(text.strip()))

    def show_problem(self, p):
        d = self.data[self.project["id"]]
        state, found = d["results"][p["id"]]
        quiet = "quiet, nothing on screen says so" if p.get("quiet") else "you would notice it"
        source = "built-in check" if p.get("source") == "git" else self.project.get("problems", "")
        self.meta.setText(html.escape(f"{p.get('area', '')}   ·   {quiet}   ·   {source}"))
        colour = {"on": TOKENS["bad"], "unknown": TOKENS["warn"], "clear": TOKENS["good"]}.get(state)
        label = STATES[state]
        self.state.setText(f"<b style='color:{colour}'>{label}</b>" if colour else f"<b>{label}</b>")
        self.state.show()
        self.foryou.setText(html.escape(p.get("means", "")))
        if p.get("now") and state in ("on", "unknown"):
            self.now.setText(f"<b>What you can do now</b><br>{html.escape(p['now'])}")
            self.now.show()
        else:
            self.now.hide()
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
        self.details_text.setText("".join(parts))
        self.details.setVisible(bool(parts))
        self.lines.hide()
        self.diff_args = []

    def show_change(self, row):
        self.state.hide()
        self.now.hide()
        self.lines.show()
        self.details.show()
        if "compare" in row:
            base, ref = row["compare"]
            self.meta.setText(html.escape(f"{base} against {ref}"))
            self.foryou.setText("Every file that differs, all the changes in the list added together.")
            self.details_text.setText("<i>Open Files and lines to see them.</i>")
            self.diff_args = ["diff", base, ref]
        else:
            f = parse(row["body"])
            bits = [row["date"], row.get("author", "")] + ([f["Values"]] if "Values" in f else [])
            self.meta.setText(html.escape("   ·   ".join(b for b in bits if b)))
            self.foryou.setText(html.escape(f.get("For you", "")) or
                                "<i>This change has no plain-words explanation. Ask Claude to explain it.</i>")
            titles = {p["id"]: p["title"] for p in self.data[self.project["id"]]["problems"]}
            self.details_text.setText(details_html(f, titles))
            self.diff_args = ["show", "--format=", row["hash"]]
        files = numstat(self.project, self.diff_args)
        self.lines.head.setText(f"Files and lines  ({len(files)})")
        self.filelist.setText(file_html(files))
        self.diff.clear()
        self.load_diff(self.lines.head.isChecked())

    def load_diff(self, on):
        # Ai - read only when opened, a big change costs nothing until then
        if on and self.diff_args and not self.diff.toPlainText():
            self.diff.setHtml(diff_html(patch(self.project, self.diff_args)))

    # Ai - notes and Claude

    def show_note(self, on):
        self.note_label.setVisible(on)
        self.note.setVisible(on)
        self.note_btn.setVisible(not on)

    def open_note(self):
        if self.current is not None:
            self.show_note(True)
            self.note.setFocus()

    def note_changed(self):
        if self.current is None:
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
        item = self.list.currentItem()
        if item is not None:
            item.setText(self.label(self.current))
        self.update_copy()

    def noted(self):
        return [k for k in self.notes if self.notes[k].get("text", "").strip()]

    def update_copy(self):
        n = len(self.noted())
        self.copy.setEnabled(n > 0)
        self.copy.setText(f"Copy {n} note{'s' if n != 1 else ''} for Claude" if n else "No notes yet")

    def copy_out(self, text, what):
        copy_text(text)
        self.say(f"{what}. Paste it into a Claude chat.")

    def copy_notes(self):
        keys = self.noted()
        if not keys or self.project is None:
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
        if self.current is None:
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
        choices += [
            ("Ask Claude for an overview of this project", "action", ("call", self.ask_overview)),
            ("Copy notes for Claude", "action", ("call", self.copy_notes)),
            ("Copy how Claude should write commits", "action",
             ("call", lambda: self.copy_out(COMMIT_STYLE, "Commit style copied"))),
            ("Copy the request for a problems file", "action",
             ("call", lambda: self.copy_out(PROBLEMS_STYLE, "Request copied"))),
            ("Add a project", "action", ("call", self.add_project)),
            ("Project settings", "action", ("call", self.edit_project)),
            ("Check again and fetch", "action", ("call", lambda: self.reload(fetch_first=True))),
            ("Show the tips again", "action", ("call", self.reset_hints)),
            ("Keyboard shortcuts", "action", ("call", self.show_keys)),
        ]
        dlg = Palette(self, choices)
        if dlg.exec() and dlg.chosen:
            kind, arg = dlg.chosen
            if kind == "project":
                self.plist.setCurrentRow(arg)
            elif kind == "follow":
                self.follow(arg)
            else:
                arg()

    def reset_hints(self):
        for h in self.hints:
            self.settings.setValue(f"hint/{h.key}", False)
        self.show_hint()

    # Ai - deep links: changes open NAME[/ITEM]

    def open_link(self, link):
        name, _, item = link.partition("/")
        for i, p in enumerate(self.projects):
            if p["name"].lower() == name.lower() or p["id"] == name:
                self.plist.setCurrentRow(i)
                self.pending = item or None
                self.open_pending()
                break
        self.raise_()
        self.activateWindow()

    def open_pending(self):
        if not self.pending or self.project is None:
            return
        if self.project["id"] in self.data:
            self.follow(self.pending)
            self.pending = None
        else:
            QTimer.singleShot(300, self.open_pending)


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
            n = (f"<span style='color:{TOKENS['good']}'>+{add}</span> "
                 f"<span style='color:{TOKENS['bad']}'>−{rem}</span>")
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
            out.append(f"<span style='color:{TOKENS['good']}'>{e}</span>")
        elif line.startswith("-"):
            out.append(f"<span style='color:{TOKENS['bad']}'>{e}</span>")
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

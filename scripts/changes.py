#!/usr/bin/env python3

# Ai - changes
#      the install's problems and changes in one window that stays open
#      Problems: what is wrong on this PC right now, quiet ones included
#      Changes: what changed in the install, in plain words
#      one thing at a time: the list shows titles, a pick shows what it
#      means for you, and everything else is folded until you open it
#      notes are kept per item and copied out for a Claude chat
#      changes              open the window
#      changes --check      check for problems, used by the hourly timer
#      changes --install    put Changes in the app launcher, once

import html
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PyQt6.QtCore import QSettings, Qt, QTimer
from PyQt6.QtGui import QColor, QFontDatabase, QGuiApplication, QKeySequence, QPalette, QShortcut
from PyQt6.QtWidgets import (
    QApplication, QComboBox, QFrame, QHBoxLayout, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QPlainTextEdit, QPushButton, QScrollArea,
    QSplitter, QStackedWidget, QTabBar, QTextEdit, QToolButton, QVBoxLayout, QWidget,
)

REPO = Path(os.environ.get("REBUILD_REPO", Path.home() / "rebuild"))
NOTES = Path.home() / ".local/share/changes/notes.json"
BRANCHES = ["v2", "v1"]
COMPARE = "compare"
CACHE = Path.home() / ".cache/changes"
SUMMARY = CACHE / "problems.txt"
SEEN = CACHE / "problems.json"


#    Tokens

# Ai - every size and colour in one place, the rest comes from your theme
#      green and red are the only fixed colours, they mean added and removed
TOKENS = {
    "added":   "#2e9e5b",
    "removed": "#d0453b",
    "gap":     8,
    "title":   1.5,
    "small":   0.9,
}


#    Git

def git(*args):
    r = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def fetch():
    # Ai - quietly, one branch at a time, an offline PC shows what it had
    for b in BRANCHES:
        subprocess.run(["git", "-C", str(REPO), "fetch", "-q", "origin", b], capture_output=True)


def entries(branch):
    rng = f"origin/{branch}" if branch == "v1" else f"origin/v1..origin/{branch}"
    out = git("log", "--date=short", "--format=%H%x1f%ad%x1f%s%x1f%b%x1e", rng)
    rows = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if rec:
            h, date, subject, body = rec.split("\x1f", 3)
            rows.append({"hash": h, "date": date, "subject": subject, "body": body})
    return rows


def parse(body):
    # Ai - Claude writes What, Why, For you, Values and Problems lines in each
    #      v2 commit, a field runs until the next field or a blank line
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


def files(args):
    rows = []
    for line in git(*args, "--numstat", "-M").splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            rows.append((parts[2], parts[0], parts[1]))
    return rows


#    Notes

def load_notes():
    try:
        return json.loads(NOTES.read_text())
    except (OSError, ValueError):
        return {}


def save_notes(notes):
    NOTES.parent.mkdir(parents=True, exist_ok=True)
    tmp = NOTES.with_suffix(".tmp")
    tmp.write_text(json.dumps(notes, indent=1))
    tmp.replace(NOTES)


#    Problems

# Ai - on: on this PC now, design: part of v1 and fixed by v2, unknown: the
#      check could not tell, clear: not on this PC
STATES = {
    "on":      "On this PC",
    "design":  "Built into v1",
    "unknown": "Could not check",
    "clear":   "Not on this PC",
}
ORDER = ["on", "design", "unknown", "clear"]


def load_problems():
    # Ai - from the repo, so a new problem shows without updating anything
    try:
        return tomllib.loads(git("show", "origin/v2:docs/problems.toml")).get("problem", [])
    except tomllib.TOMLDecodeError:
        return []


def run_check(p):
    # Ai - as you, never as root, each check only reads, five seconds at most
    if "check" not in p:
        return "design", ""
    try:
        r = subprocess.run(["sh", "-c", p["check"]], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        return "unknown", "the check took too long"
    state = {0: "on", 1: "clear"}.get(r.returncode, "unknown")
    return state, r.stdout.strip()


def run_checks(problems):
    with ThreadPoolExecutor(max_workers=8) as pool:
        return dict(zip([p["id"] for p in problems], pool.map(run_check, problems)))


def fixes(problems):
    # Ai - which v2 changes name a problem on their Problems: line
    ids = {p["id"] for p in problems}
    out = {}
    for row in entries("v2"):
        for pid in re.findall(r"[a-z0-9-]+", parse(row["body"]).get("Problems", "")):
            if pid in ids:
                out.setdefault(pid, []).append(row)
    return out


def write_summary(problems, results):
    # Ai - the few lines a new terminal prints, and a notification for a
    #      problem that was not there the last time anything checked
    on = [p for p in problems if results[p["id"]][0] == "on"]
    CACHE.mkdir(parents=True, exist_ok=True)
    if on:
        lines = [f"  {len(on)} problem{'s' if len(on) != 1 else ''} on this PC, open Changes to see why"]
        lines += [f"    {p['area']:<12}{p['title']}" for p in on]
        SUMMARY.write_text("\n".join(lines) + "\n\n")
    else:
        SUMMARY.write_text("")
    try:
        seen = set(json.loads(SEEN.read_text()))
    except (OSError, ValueError):
        seen = set()
    new = [p for p in on if p["id"] not in seen]
    SEEN.write_text(json.dumps([p["id"] for p in on]))
    if new and shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "Changes", "New problem on this PC",
                        "\n".join(p["title"] for p in new)], capture_output=True)
    return len(on)


def check_now():
    problems = load_problems()
    return write_summary(problems, run_checks(problems))


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
    pal.setColor(QPalette.ColorRole.WindowText, pal.color(QPalette.ColorGroup.Disabled, QPalette.ColorRole.WindowText))
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


class Fold(QWidget):
    # Ai - a heading with an arrow, the arrow says it opens, the body is hidden
    #      until clicked, and stays the way you left it for the next change

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
        self.set_title(name)
        self.head.setChecked(settings.value(f"open/{name}", False, type=bool))
        self.toggle(self.head.isChecked())

    def set_title(self, text):
        self.head.setText(text)

    def toggle(self, on):
        self.head.setArrowType(Qt.ArrowType.DownArrow if on else Qt.ArrowType.RightArrow)
        self.body.setVisible(on)
        self.settings.setValue(f"open/{self.name}", on)


#    Window

class Window(QMainWindow):

    def __init__(self):
        super().__init__()
        self.settings = QSettings("rebuild", "changes")
        self.setWindowTitle("Changes")
        self.resize(self.settings.value("size", None) or self.default_size())
        self.notes = load_notes()
        self.rows = {}
        self.current = None
        self.diff_args = []
        self.show_clear = False

        self.save_timer = QTimer(self, singleShot=True, interval=600)
        self.save_timer.timeout.connect(lambda: save_notes(self.notes))

        # Ai - left, the hub: two tabs, a search line and the titles

        self.tabs = QTabBar()
        self.tabs.addTab("Problems")
        self.tabs.addTab("Changes")
        self.tabs.setExpanding(False)
        self.search = QLineEdit()
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self.filter)
        self.list = QListWidget()
        self.list.setWordWrap(True)
        self.list.setSpacing(3)
        self.list.currentItemChanged.connect(self.show_item)
        self.list.itemClicked.connect(self.clicked)

        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(0, 0, 0, 0)
        lv.addWidget(self.tabs)
        lv.addWidget(self.search)
        lv.addWidget(self.list)

        # Ai - right, one problem or one change

        self.title = scaled(para(), TOKENS["title"], bold=True)
        self.meta = muted(scaled(QLabel(), TOKENS["small"]))
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

        self.note_btn = QPushButton("Add a note")
        self.note_btn.setToolTip("Ctrl+N")
        self.note_btn.clicked.connect(self.open_note)
        self.note = QPlainTextEdit(placeholderText="Your note. Saved as you type, kept on this PC.")
        self.note.setFixedHeight(self.fontMetrics().height() * 6)
        self.note.textChanged.connect(self.note_changed)
        self.note_label = scaled(QLabel("Your note"), 1, bold=True)

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
        d.addWidget(self.note_label)
        d.addWidget(self.note)
        d.addWidget(self.note_btn, alignment=Qt.AlignmentFlag.AlignLeft)
        d.addSpacing(TOKENS["gap"])
        d.addWidget(self.details)
        d.addWidget(self.lines)
        d.addStretch()

        scroll = QScrollArea(widgetResizable=True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(detail)

        # Ai - shown until something is picked, so the window never opens blank
        self.empty = muted(para())
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.pages = QStackedWidget()
        self.pages.addWidget(self.empty)
        self.pages.addWidget(scroll)

        split = QSplitter()
        split.addWidget(left)
        split.addWidget(self.pages)
        split.setStretchFactor(1, 1)
        split.setSizes([320, 780])

        # Ai - bottom bar, the version and the one action that leaves the window

        self.branch = QComboBox()
        self.branch.addItems(BRANCHES)
        self.branch.setToolTip("Which install's changes to show")
        self.branch.currentTextChanged.connect(lambda _b: self.fill())
        self.status = muted(QLabel(""))
        self.copy = QPushButton()
        self.copy.setToolTip("Ctrl+Shift+C, paste it into a Claude chat")
        self.copy.clicked.connect(self.copy_all)

        bar = QHBoxLayout()
        bar.addWidget(self.branch)
        bar.addWidget(self.status, 1)
        bar.addWidget(self.copy)

        root = QWidget()
        r = QVBoxLayout(root)
        r.addWidget(split, 1)
        r.addLayout(bar)
        self.setCentralWidget(root)

        # Ai - shortcuts, each also written on the thing it presses
        QShortcut(QKeySequence("Ctrl+F"), self, self.search.setFocus)
        QShortcut(QKeySequence("Ctrl+N"), self, self.open_note)
        QShortcut(QKeySequence("Ctrl+Shift+C"), self, self.copy_all)
        QShortcut(QKeySequence("F5"), self, self.refresh)
        QShortcut(QKeySequence("Escape"), self, self.list.setFocus)
        QShortcut(QKeySequence("Ctrl+1"), self, lambda: self.tabs.setCurrentIndex(0))
        QShortcut(QKeySequence("Ctrl+2"), self, lambda: self.tabs.setCurrentIndex(1))

        self.load()
        self.tabs.currentChanged.connect(lambda _i: self.fill())
        self.fill()
        self.update_copy()

    def default_size(self):
        from PyQt6.QtCore import QSize
        return QSize(1000, 680)

    def closeEvent(self, e):
        save_notes(self.notes)
        self.settings.setValue("size", self.size())
        super().closeEvent(e)

    def problems_mode(self):
        return self.tabs.currentIndex() == 0

    # Ai - data

    def load(self):
        self.problems = load_problems()
        self.results = run_checks(self.problems)
        self.fixed_by = fixes(self.problems)
        write_summary(self.problems, self.results)
        on = sum(1 for p in self.problems if self.results[p["id"]][0] == "on")
        self.tabs.setTabText(0, f"Problems  {on}" if on else "Problems")

    def refresh(self):
        self.status.setText("Checking...")
        QApplication.processEvents()
        fetch()
        self.load()
        self.fill()
        self.status.setText("Up to date")

    # Ai - list

    def fill(self):
        self.list.clear()
        self.rows = {}
        self.current = None
        problems = self.problems_mode()
        self.branch.setVisible(not problems)
        self.search.setPlaceholderText(f"Search {'problems' if problems else 'changes'}   Ctrl+F")
        if problems:
            self.fill_problems()
        else:
            self.fill_changes(self.branch.currentText())
        self.filter(self.search.text())
        self.pages.setCurrentIndex(0)

    def fill_problems(self):
        # Ai - grouped by state, worst first, what is not on this PC is folded
        groups = {s: [] for s in ORDER}
        for p in self.problems:
            groups[self.results[p["id"]][0]].append(p)
        for s in ORDER:
            if not groups[s]:
                continue
            folded = s == "clear" and not self.show_clear
            arrow = ("  ▸" if folded else "  ▾") if s == "clear" else ""
            head = QListWidgetItem(f"{STATES[s]}  ({len(groups[s])}){arrow}")
            f = head.font()
            f.setBold(True)
            head.setFont(f)
            head.setFlags(Qt.ItemFlag.ItemIsEnabled)
            head.setData(Qt.ItemDataRole.UserRole, f"group:{s}")
            self.list.addItem(head)
            for p in groups[s]:
                key = f"problem:{p['id']}"
                self.rows[key] = {"kind": "problem", "p": p, "subject": p["title"], "date": "",
                                  "body": p.get("means", "") + " " + p.get("area", "")}
                self.add_item(key)
                self.list.item(self.list.count() - 1).setData(Qt.ItemDataRole.UserRole + 1, folded)
        on = len(groups["on"])
        self.status.setText(f"{on} on this PC, {len(groups['design'])} built into v1")
        self.empty.setText("Pick a problem on the left." if self.problems else
                           "No problem list found. Press F5 to fetch it.")

    def fill_changes(self, branch):
        for row in entries(branch):
            row["kind"] = "change"
            self.rows[row["hash"]] = row
            self.add_item(row["hash"])
        if branch != "v1":
            key = f"{COMPARE}:v1..{branch}"
            self.rows[key] = {"kind": "change", "hash": key, "date": "",
                              "subject": f"All of {branch} compared to v1", "body": "", "compare": branch}
            self.add_item(key)
        self.status.setText(f"{len(self.rows) - (branch != 'v1')} changes")
        self.empty.setText("Pick a change on the left.")

    def label(self, key):
        noted = bool(self.notes.get(key, {}).get("text", "").strip())
        return self.rows[key]["subject"] + ("   ✎" if noted else "")

    def add_item(self, key):
        it = QListWidgetItem(self.label(key))
        it.setData(Qt.ItemDataRole.UserRole, key)
        row = self.rows[key]
        if row["kind"] == "problem":
            it.setToolTip(row["p"]["area"])
            if self.results[row["p"]["id"]][0] == "on":
                it.setForeground(QColor(TOKENS["removed"]))
        else:
            it.setToolTip(row["date"] or "everything at once")
        self.list.addItem(it)

    def clicked(self, item):
        if item.data(Qt.ItemDataRole.UserRole) == "group:clear":
            self.show_clear = not self.show_clear
            self.fill()

    def filter(self, text):
        t = text.lower().strip()
        for i in range(self.list.count()):
            it = self.list.item(i)
            key = it.data(Qt.ItemDataRole.UserRole)
            if key.startswith("group:"):
                it.setHidden(bool(t))
                continue
            row = self.rows[key]
            hay = (row["subject"] + " " + row["body"]).lower()
            folded = bool(it.data(Qt.ItemDataRole.UserRole + 1)) and not t
            it.setHidden(folded or (bool(t) and t not in hay))

    def follow(self, link):
        # Ai - links between a problem and the changes that fix it
        kind, _, key = link.partition(":")
        if kind == "change":
            self.tabs.setCurrentIndex(1)
            self.branch.setCurrentText("v2")
        elif kind == "problem":
            self.tabs.setCurrentIndex(0)
            key = f"problem:{key}"
            if key not in self.rows:
                self.show_clear = True
                self.fill()
        self.search.clear()
        for i in range(self.list.count()):
            if self.list.item(i).data(Qt.ItemDataRole.UserRole) == key:
                self.list.setCurrentRow(i)
                break

    # Ai - one item

    def show_item(self, item, _old=None):
        if item is None:
            return
        key = item.data(Qt.ItemDataRole.UserRole)
        if key.startswith("group:"):
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
        state, found = self.results[p["id"]]
        self.meta.setText(f"{p['area']}   ·   {'quiet, nothing on screen says so' if p.get('quiet') else 'you would notice it'}")
        colour = {"on": TOKENS["removed"], "clear": TOKENS["added"]}.get(state)
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
            parts.append(f"<p><b>How v2 fixes it</b><br>{html.escape(p['v2'])}</p>")
        done = self.fixed_by.get(p["id"], [])
        if done:
            links = "<br>".join(f"<a href='change:{r['hash']}'>{html.escape(r['subject'])}</a>" for r in done)
            parts.append(f"<p><b>Fixed in v2 by</b><br>{links}</p>")
        if p.get("check"):
            parts.append("<p><b>How it is checked</b><br>A short read-only test, run as you:</p>"
                         f"<pre>{html.escape(p['check'].strip())}</pre>")
        self.details_text.setText("".join(parts) or "<i>Nothing more for this one.</i>")
        self.lines.hide()
        self.diff_args = []

    def show_change(self, row):
        self.state.hide()
        self.now.hide()
        self.lines.show()
        if "compare" in row:
            self.meta.setText(f"v1 against {row['compare']}")
            self.foryou.setText("Every file that differs between the two installs, in one place.")
            self.details_text.setText("<i>This is the sum of all the changes in the list.</i>")
            self.diff_args = ["diff", "-M", "origin/v1", f"origin/{row['compare']}"]
        else:
            f = parse(row["body"])
            bits = [row["date"]] + ([f["Values"]] if "Values" in f else [])
            self.meta.setText("   ·   ".join(bits))
            self.foryou.setText(html.escape(f.get("For you", ""))
                                or "<i>No explanation was written for this change.</i>")
            self.details_text.setText(details_html(f, {p["id"]: p["title"] for p in self.problems}))
            self.diff_args = ["show", "--format=", "-M", row["hash"]]

        rows = files(self.diff_args)
        self.lines.set_title(f"Files and lines  ({len(rows)})")
        self.filelist.setText(file_html(rows))
        self.diff.clear()
        self.load_diff(self.lines.head.isChecked())

    def load_diff(self, on):
        # Ai - read only when opened, a big change costs nothing until then
        if on and self.diff_args and not self.diff.toPlainText():
            self.diff.setHtml(diff_html(git(*self.diff_args, "--patch")))

    # Ai - notes

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
                                        "branch": "problem", "what": p.get("means", ""),
                                        "state": STATES[self.results[p["id"]][0]]}
        else:
            self.notes[self.current] = {"text": text, "subject": row["subject"], "date": row["date"],
                                        "branch": self.branch.currentText(),
                                        "what": parse(row["body"]).get("What", "")}
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

    def copy_all(self):
        keys = self.noted()
        if not keys:
            return
        # Ai - problems first, then changes newest first
        keys.sort(key=lambda k: (not k.startswith("problem:"), self.notes[k].get("date") or ""))
        probs = [k for k in keys if k.startswith("problem:")]
        changes = sorted([k for k in keys if not k.startswith("problem:")],
                         key=lambda k: self.notes[k].get("date") or "", reverse=True)
        out = ["My notes on my install:", ""]
        for k in probs + changes:
            n = self.notes[k]
            if k.startswith("problem:"):
                out.append(f"Problem: {n['subject']} ({n.get('state', '')})")
                out.append(f"What it means: {n['what']}")
            else:
                ref = "all changes" if k.startswith(COMPARE) else k[:7]
                out.append(f"Change {ref} ({n['branch']}, {n['date'] or 'all'}): {n['subject']}")
                if n.get("what"):
                    out.append(f"What it does: {n['what']}")
            out.append(f"My note: {n['text'].strip()}")
            out.append("")
        copy_text("\n".join(out))
        self.status.setText("Copied. Paste it into a Claude chat.")


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
            n = (f"<span style='color:{TOKENS['added']}'>+{add}</span> "
                 f"<span style='color:{TOKENS['removed']}'>−{rem}</span>")
        out.append(f"{html.escape(path)} &nbsp; {n}")
    if len(rows) > 60:
        out.append(f"<i>and {len(rows) - 60} more</i>")
    return "<br>".join(out)


def diff_html(text):
    # Ai - one bold heading per file, green added, red removed, git's own
    #      bookkeeping lines are left out
    out = []
    lines = text.splitlines()
    for line in lines[:4000]:
        if line.startswith(("index ", "--- ", "+++ ", "similarity ", "new file", "deleted file")):
            continue
        e = html.escape(line) or "&nbsp;"
        if line.startswith("diff --git"):
            name = line.split(" b/", 1)[-1]
            out.append(f"\n<b>{html.escape(name)}</b>")
        elif line.startswith("rename "):
            out.append(f"<i>{e}</i>")
        elif line.startswith("+"):
            out.append(f"<span style='color:{TOKENS['added']}'>{e}</span>")
        elif line.startswith("-"):
            out.append(f"<span style='color:{TOKENS['removed']}'>{e}</span>")
        elif line.startswith("@@"):
            out.append("<i>…</i>")
        else:
            out.append(e)
    if len(lines) > 4000:
        out.append("<i>cut at 4000 lines</i>")
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
	mv "$CACHE.new" "$CACHE"
else
	rm -f "$CACHE.new"
fi
exec python3 "$CACHE" "$@"
"""


# Ai - the hourly check and the terminal line, set up by the window itself
#      the first time it opens, so nothing has to be run by hand
UNIT = """[Unit]
Description=Check this PC for known problems

[Service]
Type=oneshot
ExecStart=/usr/local/bin/changes --check
"""

TIMER = """[Unit]
Description=Check this PC for known problems every hour

[Timer]
OnStartupSec=2min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
"""

BASHRC_LINE = '[ -s "$HOME/.cache/changes/problems.txt" ] && cat "$HOME/.cache/changes/problems.txt"  # changes'


def ensure_hooks():
    units = Path.home() / ".config/systemd/user"
    timer = units / "changes-check.timer"
    if not timer.exists():
        units.mkdir(parents=True, exist_ok=True)
        (units / "changes-check.service").write_text(UNIT)
        timer.write_text(TIMER)
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "--user", "enable", "--now", "changes-check.timer"], capture_output=True)
    rc = Path.home() / ".bashrc"
    try:
        current = rc.read_text()
    except OSError:
        current = ""
    if "# changes" not in current:
        with rc.open("a") as fh:
            fh.write(("" if current.endswith("\n") or not current else "\n") + BASHRC_LINE + "\n")


def install():
    ensure_hooks()
    apps = Path.home() / ".local/share/applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / "changes.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Changes\n"
        "Comment=What changed in the install, in plain words\n"
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


def main():
    if sys.argv[1:] == ["--install"]:
        install()
        return
    if not (REPO / ".git").exists():
        print(f"no repo at {REPO}", file=sys.stderr)
        sys.exit(1)
    if sys.argv[1:] == ["--check"]:
        fetch()
        print(f"{check_now()} problem(s) on this PC")
        return
    ensure_hooks()
    app = QApplication(sys.argv)
    app.setApplicationName("changes")
    app.setDesktopFileName("changes")
    fetch()
    w = Window()
    w.show()
    QTimer.singleShot(400, float_window)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

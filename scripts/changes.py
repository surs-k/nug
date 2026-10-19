#!/usr/bin/env python3

# Ai - changes
#      every change to the install in one window that stays open
#      the left is the list, the right says what a change did, why, and what
#      it means for you, in plain words, the exact lines are one click away
#      a note can be kept on any change, and copied out for a Claude chat
#      changes              open the window
#      changes --install    put Changes in the app launcher

import html
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFont, QGuiApplication
from PyQt6.QtWidgets import (
    QApplication, QComboBox, QFrame, QHBoxLayout, QLabel, QListWidget,
    QListWidgetItem, QMainWindow, QPlainTextEdit, QPushButton, QScrollArea,
    QSplitter, QTextEdit, QVBoxLayout, QWidget,
)

REPO = Path(os.environ.get("REBUILD_REPO", Path.home() / "rebuild"))
NOTES = Path.home() / ".local/share/changes/notes.json"
BRANCHES = ["v2", "v1"]
COMPARE = "compare"

# Ai - the parts of a commit message this window reads, each starts a line
#      Claude writes every v2 commit this way, v1 commits only have a title
FIELDS = {"What": "What it does", "Why": "Why", "For you": "What it means for you",
          "Values": "Values", "Problems": "Problems"}


#    Git

def git(*args):
    r = subprocess.run(["git", "-C", str(REPO), *args],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def fetch():
    # Ai - quietly, an offline PC shows what it fetched last time
    #      one at a time, a missing branch does not stop the other
    for b in BRANCHES:
        subprocess.run(["git", "-C", str(REPO), "fetch", "-q", "origin", b],
                       capture_output=True)


def entries(branch):
    rng = f"origin/{branch}" if branch == "v1" else f"origin/v1..origin/{branch}"
    out = git("log", "--date=short", "--format=%H%x1f%ad%x1f%s%x1f%b%x1e", rng)
    rows = []
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        h, date, subject, body = rec.split("\x1f", 3)
        rows.append({"hash": h, "date": date, "subject": subject, "body": body})
    return rows


def parse(body):
    # Ai - a field runs until the next field or a blank line
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
    # Ai - one row per file, with how many lines came and went
    rows = []
    for line in git(*args, "--numstat", "-M").splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            add, rem, path = parts
            rows.append((path, add, rem))
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


#    Window

class Window(QMainWindow):

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Changes")
        self.resize(1100, 720)
        self.notes = load_notes()
        self.current = None
        self.rows = {}

        self.save_timer = QTimer(self, singleShot=True, interval=600)
        self.save_timer.timeout.connect(lambda: save_notes(self.notes))

        # Ai - top bar
        self.branch = QComboBox()
        self.branch.addItems(BRANCHES)
        self.branch.currentTextChanged.connect(self.fill)
        refresh = QPushButton("Refresh")
        refresh.clicked.connect(self.refresh)
        copy_all = QPushButton("Copy all notes for Claude")
        copy_all.clicked.connect(self.copy_all)
        self.status = QLabel("")

        bar = QHBoxLayout()
        bar.addWidget(QLabel("Version"))
        bar.addWidget(self.branch)
        bar.addWidget(refresh)
        bar.addStretch()
        bar.addWidget(self.status)
        bar.addWidget(copy_all)

        # Ai - the list
        self.list = QListWidget()
        self.list.setWordWrap(True)
        self.list.setSpacing(4)
        self.list.currentItemChanged.connect(self.show_item)

        # Ai - the detail, plain words first, the lines last and hidden
        self.title = QLabel()
        self.title.setWordWrap(True)
        f = self.title.font()
        f.setPointSizeF(f.pointSizeF() * 1.4)
        f.setBold(True)
        self.title.setFont(f)
        self.meta = QLabel()
        self.meta.setEnabled(False)
        self.text = QLabel()
        self.text.setWordWrap(True)
        self.text.setTextFormat(Qt.TextFormat.RichText)
        self.text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.filelist = QLabel()
        self.filelist.setWordWrap(True)
        self.filelist.setTextFormat(Qt.TextFormat.RichText)

        self.lines_btn = QPushButton("Show the exact lines")
        self.lines_btn.setCheckable(True)
        self.lines_btn.toggled.connect(self.toggle_lines)
        self.lines = QTextEdit(readOnly=True)
        self.lines.setFont(QFontDatabase_fixed())
        self.lines.setMinimumHeight(320)
        self.lines.hide()

        self.note = QPlainTextEdit()
        self.note.setPlaceholderText("Your note on this change. Saved as you type.")
        self.note.setFixedHeight(110)
        self.note.textChanged.connect(self.note_changed)
        copy_one = QPushButton("Copy this note for Claude")
        copy_one.clicked.connect(self.copy_one)

        detail = QWidget()
        d = QVBoxLayout(detail)
        d.addWidget(self.title)
        d.addWidget(self.meta)
        d.addWidget(self.text)
        d.addWidget(heading("Files"))
        d.addWidget(self.filelist)
        d.addWidget(self.lines_btn, alignment=Qt.AlignmentFlag.AlignLeft)
        d.addWidget(self.lines)
        d.addWidget(heading("Your note"))
        d.addWidget(self.note)
        d.addWidget(copy_one, alignment=Qt.AlignmentFlag.AlignLeft)
        d.addStretch()

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(detail)

        split = QSplitter()
        split.addWidget(self.list)
        split.addWidget(scroll)
        split.setSizes([360, 740])

        root = QWidget()
        r = QVBoxLayout(root)
        r.addLayout(bar)
        r.addWidget(split)
        self.setCentralWidget(root)

        self.fill(self.branch.currentText())

    def closeEvent(self, e):
        # Ai - a note typed just before closing is not lost
        save_notes(self.notes)
        super().closeEvent(e)

    # Ai - list

    def refresh(self):
        self.status.setText("Fetching...")
        QApplication.processEvents()
        fetch()
        self.fill(self.branch.currentText())
        self.status.setText("Up to date")

    def fill(self, branch):
        self.list.clear()
        self.rows = {}
        if branch != "v1":
            key = f"{COMPARE}:v1..{branch}"
            self.rows[key] = {"hash": key, "date": "", "subject": "Everything since v1",
                              "body": "", "compare": branch}
            self.add_item(key)
        for row in entries(branch):
            self.rows[row["hash"]] = row
            self.add_item(row["hash"])
        if self.list.count() > 1:
            self.list.setCurrentRow(1)
        elif self.list.count():
            self.list.setCurrentRow(0)

    def label(self, key, noted):
        row = self.rows[key]
        top = row["date"] or "v1 to now"
        return f"{top}{'   ✎ note' if noted else ''}\n{row['subject']}"

    def add_item(self, key):
        noted = bool(self.notes.get(key, {}).get("text", "").strip())
        it = QListWidgetItem(self.label(key, noted))
        it.setData(Qt.ItemDataRole.UserRole, key)
        self.list.addItem(it)

    # Ai - detail

    def show_item(self, item, _old=None):
        if item is None:
            return
        key = item.data(Qt.ItemDataRole.UserRole)
        row = self.rows[key]
        self.current = key
        self.title.setText(row["subject"])

        if "compare" in row:
            self.meta.setText(f"v1 against {row['compare']}, every file that differs")
            self.diff_args = ["diff", "-M", "origin/v1", f"origin/{row['compare']}"]
            self.text.setText("<p>All of the changes below, added together.</p>")
        else:
            self.meta.setText(f"{row['date']}   ·   {row['hash'][:7]}")
            self.diff_args = ["show", "--format=", "-M", row["hash"]]
            self.text.setText(explain(parse(row["body"])))

        rows = files(self.diff_args)
        self.filelist.setText(file_html(rows))

        self.lines_btn.setChecked(False)
        self.lines.hide()

        self.note.blockSignals(True)
        self.note.setPlainText(self.notes.get(key, {}).get("text", ""))
        self.note.blockSignals(False)

    def toggle_lines(self, on):
        if on:
            self.lines.setHtml(diff_html(git(*self.diff_args, "--patch")))
            self.lines.show()
            self.lines_btn.setText("Hide the exact lines")
        else:
            self.lines.hide()
            self.lines_btn.setText("Show the exact lines")

    # Ai - notes

    def note_changed(self):
        if self.current is None:
            return
        row = self.rows[self.current]
        text = self.note.toPlainText()
        if text.strip():
            self.notes[self.current] = {"text": text, "subject": row["subject"],
                                        "date": row["date"], "branch": self.branch.currentText()}
        else:
            self.notes.pop(self.current, None)
        self.save_timer.start()
        item = self.list.currentItem()
        if item is not None:
            item.setText(self.label(self.current, bool(text.strip())))

    def block(self, key):
        n = self.notes[key]
        row = self.rows.get(key, {})
        what = parse(row.get("body", "")).get("What", "")
        ref = "everything since v1" if key.startswith(COMPARE) else key[:7]
        out = f"Change {ref} ({n['branch']}, {n['date'] or 'all'}): {n['subject']}\n"
        if what:
            out += f"What it does: {what}\n"
        out += f"My note: {n['text'].strip()}\n"
        return out

    def copy_one(self):
        if self.current in self.notes:
            copy_text("My note on an install change:\n\n" + self.block(self.current))
            self.status.setText("Copied, paste it into Claude")
        else:
            self.status.setText("No note on this change yet")

    def copy_all(self):
        keys = [k for k in self.notes if self.notes[k].get("text", "").strip()]
        if not keys:
            self.status.setText("No notes yet")
            return
        keys.sort(key=lambda k: self.notes[k].get("date") or "", reverse=True)
        copy_text("My notes on install changes:\n\n" + "\n".join(self.block(k) for k in keys))
        self.status.setText(f"{len(keys)} note(s) copied, paste them into Claude")


#    Helpers

def heading(text):
    lab = QLabel(text)
    f = lab.font()
    f.setBold(True)
    lab.setFont(f)
    lab.setContentsMargins(0, 12, 0, 0)
    return lab


def QFontDatabase_fixed():
    from PyQt6.QtGui import QFontDatabase
    return QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)


def explain(fields):
    if not fields:
        return "<p><i>No plain-words explanation for this change, only its title.</i></p>"
    out = ""
    for key, label in FIELDS.items():
        if key in fields:
            out += f"<p><b>{label}</b><br>{html.escape(fields[key])}</p>"
    return out


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
            n = "binary"
        else:
            n = (f"<span style='color:#2e9e5b'>+{add}</span> "
                 f"<span style='color:#d0453b'>−{rem}</span>")
        out.append(f"{html.escape(path)} &nbsp; {n}")
    if len(rows) > 60:
        out.append(f"<i>and {len(rows) - 60} more</i>")
    return "<br>".join(out)


def diff_html(text):
    # Ai - green is added, red is removed, grey says where in the file
    lines = text.splitlines()
    cut = len(lines) > 4000
    out = []
    for line in lines[:4000]:
        e = html.escape(line) or "&nbsp;"
        if line.startswith(("+++", "---", "diff ", "index ", "rename ", "similarity ", "new file", "deleted file")):
            out.append(f"<b>{e}</b>")
        elif line.startswith("+"):
            out.append(f"<span style='color:#2e9e5b'>{e}</span>")
        elif line.startswith("-"):
            out.append(f"<span style='color:#d0453b'>{e}</span>")
        elif line.startswith("@@"):
            out.append(f"<span style='color:#888888'>{e}</span>")
        else:
            out.append(e)
    if cut:
        out.append("<i>cut at 4000 lines</i>")
    return "<pre>" + "\n".join(out) + "</pre>"


def copy_text(text):
    # Ai - wl-copy keeps it after the window closes, Qt's copy is the fallback
    if shutil.which("wl-copy"):
        subprocess.run(["wl-copy"], input=text, text=True)
    QGuiApplication.clipboard().setText(text)


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


def install():
    apps = Path.home() / ".local/share/applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / "changes.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Changes\n"
        "Comment=What changed in the install, in plain words\n"
        "Exec=changes\nIcon=document-open-recent\nTerminal=false\n"
        "StartupWMClass=changes\n")
    print("Changes is in the app launcher")


#    Main

def main():
    if sys.argv[1:] == ["--install"]:
        install()
        return
    if not (REPO / ".git").exists():
        print(f"no repo at {REPO}", file=sys.stderr)
        sys.exit(1)
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

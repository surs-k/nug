#!/usr/bin/env python3

# Ai - changes
#      every change to the install in one window that stays open
#      one thing at a time: the list shows titles, a change shows what it
#      means for you, and everything else is folded until you open it
#      notes are kept per change and copied out for a Claude chat
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

from PyQt6.QtCore import QSettings, Qt, QTimer
from PyQt6.QtGui import QFontDatabase, QGuiApplication, QKeySequence, QPalette, QShortcut
from PyQt6.QtWidgets import (
    QApplication, QComboBox, QFrame, QHBoxLayout, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QPlainTextEdit, QPushButton, QScrollArea,
    QSplitter, QStackedWidget, QTextEdit, QToolButton, QVBoxLayout, QWidget,
)

REPO = Path(os.environ.get("REBUILD_REPO", Path.home() / "rebuild"))
NOTES = Path.home() / ".local/share/changes/notes.json"
BRANCHES = ["v2", "v1"]
COMPARE = "compare"


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
    lab.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
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

        self.save_timer = QTimer(self, singleShot=True, interval=600)
        self.save_timer.timeout.connect(lambda: save_notes(self.notes))

        # Ai - left, the hub: a search line and the titles

        self.search = QLineEdit(placeholderText="Search changes   Ctrl+F")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self.filter)
        self.list = QListWidget()
        self.list.setWordWrap(True)
        self.list.setSpacing(3)
        self.list.currentItemChanged.connect(self.show_item)

        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(0, 0, 0, 0)
        lv.addWidget(self.search)
        lv.addWidget(self.list)

        # Ai - right, one change

        self.title = scaled(para(), TOKENS["title"], bold=True)
        self.meta = muted(scaled(QLabel(), TOKENS["small"]))
        self.foryou = para()
        self.details = Fold("Details", self.settings)
        self.details_text = para()
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
        d.addSpacing(TOKENS["gap"])
        d.addWidget(self.foryou)
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

        # Ai - shown until a change is picked, so the window never opens blank
        empty = muted(para("Pick a change on the left."))
        empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.pages = QStackedWidget()
        self.pages.addWidget(empty)
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
        self.branch.currentTextChanged.connect(self.fill)
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

        self.fill(self.branch.currentText())
        self.update_copy()

    def default_size(self):
        from PyQt6.QtCore import QSize
        return QSize(1000, 680)

    def closeEvent(self, e):
        save_notes(self.notes)
        self.settings.setValue("size", self.size())
        super().closeEvent(e)

    # Ai - list

    def refresh(self):
        self.status.setText("Checking for new changes...")
        QApplication.processEvents()
        fetch()
        self.fill(self.branch.currentText())
        self.status.setText("Up to date")

    def fill(self, branch):
        self.list.clear()
        self.rows = {}
        for row in entries(branch):
            self.rows[row["hash"]] = row
            self.add_item(row["hash"])
        if branch != "v1":
            key = f"{COMPARE}:v1..{branch}"
            self.rows[key] = {"hash": key, "date": "", "subject": f"All of {branch} compared to v1",
                              "body": "", "compare": branch}
            self.add_item(key)
        self.filter(self.search.text())
        self.pages.setCurrentIndex(0)
        self.status.setText(f"{len(self.rows) - (branch != 'v1')} changes")

    def label(self, key):
        noted = bool(self.notes.get(key, {}).get("text", "").strip())
        return self.rows[key]["subject"] + ("   ✎" if noted else "")

    def add_item(self, key):
        it = QListWidgetItem(self.label(key))
        it.setData(Qt.ItemDataRole.UserRole, key)
        row = self.rows[key]
        it.setToolTip(row["date"] or "everything at once")
        self.list.addItem(it)

    def filter(self, text):
        t = text.lower().strip()
        for i in range(self.list.count()):
            it = self.list.item(i)
            row = self.rows[it.data(Qt.ItemDataRole.UserRole)]
            hay = (row["subject"] + " " + row["body"]).lower()
            it.setHidden(bool(t) and t not in hay)

    # Ai - one change

    def show_item(self, item, _old=None):
        if item is None:
            return
        key = item.data(Qt.ItemDataRole.UserRole)
        row = self.rows[key]
        self.current = key
        self.pages.setCurrentIndex(1)
        self.title.setText(html.escape(row["subject"]))

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
            self.details_text.setText(details_html(f))
            self.diff_args = ["show", "--format=", "-M", row["hash"]]

        rows = files(self.diff_args)
        self.lines.set_title(f"Files and lines  ({len(rows)})")
        self.filelist.setText(file_html(rows))
        self.diff.clear()
        self.load_diff(self.lines.head.isChecked())

        text = self.notes.get(key, {}).get("text", "")
        self.note.blockSignals(True)
        self.note.setPlainText(text)
        self.note.blockSignals(False)
        self.show_note(bool(text.strip()))

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
        if text.strip():
            self.notes[self.current] = {"text": text, "subject": row["subject"], "date": row["date"],
                                        "branch": self.branch.currentText(),
                                        "what": parse(row["body"]).get("What", "")}
        else:
            self.notes.pop(self.current, None)
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
        keys = sorted(self.noted(), key=lambda k: self.notes[k].get("date") or "", reverse=True)
        if not keys:
            return
        out = ["My notes on install changes:", ""]
        for k in keys:
            n = self.notes[k]
            ref = "all changes" if k.startswith(COMPARE) else k[:7]
            out.append(f"Change {ref} ({n['branch']}, {n['date'] or 'all'}): {n['subject']}")
            if n.get("what"):
                out.append(f"What it does: {n['what']}")
            out.append(f"My note: {n['text'].strip()}")
            out.append("")
        copy_text("\n".join(out))
        self.status.setText("Copied. Paste it into a Claude chat.")


#    Text

def details_html(f):
    labels = {"What": "What it does", "Why": "Why", "Problems": "Problems it fixes"}
    out = "".join(f"<p><b>{lab}</b><br>{html.escape(f[k])}</p>" for k, lab in labels.items() if k in f)
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


def install():
    apps = Path.home() / ".local/share/applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / "changes.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Changes\n"
        "Comment=What changed in the install, in plain words\n"
        "Exec=changes\nIcon=document-open-recent\nTerminal=false\n"
        "StartupWMClass=changes\n")
    print("Changes is in the app launcher")


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

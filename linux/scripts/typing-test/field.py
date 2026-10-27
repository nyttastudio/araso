#!/usr/bin/env python3
"""A GTK 3 text field for the typing test: what it holds goes to the file given, on every change.
It types through fcitx5's GTK module like any app (GTK_IM_MODULE=fcitx)."""
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

out = sys.argv[1]
window = Gtk.Window(title="Araso typing test")
window.set_default_size(600, 200)
view = Gtk.TextView()
buffer = view.get_buffer()


def changed(_):
    start, end = buffer.get_bounds()
    with open(out, "w", encoding="utf-8") as file:
        file.write(buffer.get_text(start, end, True))


buffer.connect("changed", changed)
window.add(view)
window.connect("destroy", Gtk.main_quit)
window.show_all()
view.grab_focus()
Gtk.main()

"""Exercise the Rust session interface that the native app calls."""

import argparse
import ctypes
import json
import sys
from pathlib import Path


class Session:
    def __init__(self, path):
        self.lib = ctypes.CDLL(str(path))
        self.lib.ahampo_session_create.restype = ctypes.c_void_p
        self.lib.ahampo_session_destroy.argtypes = [ctypes.c_void_p]
        self.lib.ahampo_session_apply.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        self.lib.ahampo_session_apply.restype = ctypes.c_void_p
        self.lib.ahampo_string_free.argtypes = [ctypes.c_void_p]
        self.handle = self.lib.ahampo_session_create()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.lib.ahampo_session_destroy(self.handle)

    def send(self, kind, **values):
        request = json.dumps({"kind": kind, **values}).encode()
        pointer = self.lib.ahampo_session_apply(self.handle, request)
        if not pointer:
            raise RuntimeError("Session returned no response")
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.lib.ahampo_string_free(pointer)


def reading(session):
    session.send("draft", text="Original draft")
    state = session.send("read", source="The selected paragraph.")
    task = state["task"]
    assert task > 0 and state["phase"] == "loading"
    state = session.send("play", task=task)
    assert state["phase"] == "playing"
    state = session.send("reading_view", view="draft")
    assert state["reading_view"] == "draft"
    state = session.send("draft", text="Revised draft")
    assert state["snapshot"] == "The selected paragraph."
    assert state["draft"] == "Revised draft"
    state = session.send("reading_view", view="compact")
    assert state["reading_view"] == "compact" and state["phase"] == "playing"
    state = session.send("read_done", task=task)
    assert state["phase"] == "standard" and state["draft"] == "Revised draft"


def dictation(session):
    session.send("draft", text="Before 😀 selected after.", caret=18)
    state = session.send("dictate", external=False)
    task = state["task"]
    assert state["phase"] == "recording"
    state = session.send("pause", task=task)
    assert state["phase"] == "dictation_paused"
    state = session.send("pause", task=task)
    assert state["phase"] == "recording"
    state = session.send("finish", task=task)
    assert state["phase"] == "finishing"
    state = session.send("transcript", task=task, text="new phrase")
    assert state["draft"] == "Before 😀 selected new phrase after."
    again = session.send("transcript", task=task, text="new phrase")
    assert again["draft"] == state["draft"]


def expired(session):
    session.send("draft", text="Keep this until expiry")
    session.send("show", now=0)
    assert session.send("tick", now=900000)["draft"] == "Keep this until expiry"
    session.send("hide", now=900001)
    assert session.send("tick", now=1200000)["draft"] == "Keep this until expiry"
    state = session.send("tick", now=1200001)
    assert state["draft"] == "" and state["offload"]
    assert not session.send("tick", now=1200002)["offload"]


def canceled(session):
    session.send("draft", text="Protected")
    take = session.send("dictate", external=False)["task"]
    session.send("cancel")
    new_take = session.send("dictate", external=True)["task"]
    state = session.send("transcript", task=take, text="Stale")
    assert new_take != take and state["task"] == new_take
    assert state["draft"] == "Protected" and state["phase"] == "recording"
    session.send("finish", task=new_take)
    state = session.send("transcript", task=new_take, text="Recovered")
    assert state["recovery"] == "Recovered" and state["draft"] == "Protected"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    passed = True
    for name, case in (("reading", reading), ("dictation", dictation), ("expired", expired), ("canceled", canceled)):
        try:
            with Session(args.library.resolve()) as session:
                case(session)
            print(f"{name}: passed")
        except (KeyError, AssertionError, RuntimeError, OSError) as error:
            print(f"{name}: failed at {error or 'assertion'}", file=sys.stderr)
            passed = False
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())

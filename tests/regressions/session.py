"""Regressions on the same Rust interface the macOS app calls."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "acceptance"))
from core_probe import Session


def finish(session, text):
    task = session.send("dictate", external=True)["task"]
    session.send("finish", task=task)
    return session.send("transcript", task=task, text=text)


def preserved_recovery(session):
    session.send("draft", text="Draft")
    assert finish(session, "First recovery")["recovery"] == "First recovery"
    assert finish(session, "")["recovery"] == "First recovery"
    assert finish(session, "Second recovery")["recovery"] == "First recovery"
    state = session.send("insert_recovery")
    assert state["draft"] == "Draft\nFirst recovery"
    assert state["recovery"] == "Second recovery"
    state = session.send("insert_recovery")
    assert state["draft"] == "Draft\nFirst recovery Second recovery"
    assert state["recovery"] is None


def retry_recognition(session):
    task = session.send("dictate", external=False)["task"]
    session.send("finish", task=task)
    assert session.send("recognition_failed", task=task + 1)["phase"] == "finishing"
    paused = session.send("recognition_failed", task=task)
    assert paused["phase"] == "dictation_paused" and paused["task"] == task
    session.send("finish", task=task)
    assert session.send("transcript", task=task, text="Retried")["draft"] == "Retried"
    assert session.send("transcript", task=task, text="Duplicate")["draft"] == "Retried"


def edit_review_without_changing_draft(session):
    session.send("draft", text="Before after", caret=7)
    assert finish(session, "Original")["draft"] == "Before after"
    assert session.send("edit_recovery", text="edited")["recovery"] == "edited"
    reading = session.send("read", source="edited")
    assert reading["snapshot"] == "edited"
    assert session.send("edit_recovery", text="Ignored during playback")["recovery"] == "edited"
    session.send("read_done", task=reading["task"])
    inserted = session.send("insert_recovery")
    assert inserted["draft"] == "Before edited after"
    assert inserted["recovery"] is None
    assert session.send("insert_recovery")["draft"] == "Before edited after"


def expiry_keeps_original_deadline(session):
    session.send("show", now=1000)
    session.send("draft", text="Disposable")
    session.send("hide", now=2000)
    updated = session.send("policy", idle_ms=60000, keep_loaded=False, now=60000)
    assert updated["hidden_since"] == 2000
    assert not session.send("tick", now=61999)["offload"]
    assert session.send("tick", now=62000)["offload"]


if __name__ == "__main__":
    library = Path(sys.argv[1]).resolve()
    for scenario in (preserved_recovery, retry_recognition, edit_review_without_changing_draft,
                     expiry_keeps_original_deadline):
        with Session(library) as session:
            scenario(session)
        print(f"{scenario.__name__}: passed")

#!/usr/bin/python3
"""Passive Codex hooks: publish only state metadata to the local desktop pet."""

import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time


ACTIVITIES = {"UserPromptSubmit": "thinking", "Stop": "idle", "Interrupt": "idle"}
EFFORTS = {"low", "medium", "high", "xhigh", "ultra"}


def read_effort(session_id, codex_home):
    """The hook input has no effort field; query only this session's metadata."""
    databases = sorted(
        Path(codex_home).glob("state_*.sqlite"),
        key=lambda path: int(path.stem.split("_")[-1]) if path.stem.split("_")[-1].isdigit() else -1,
        reverse=True,
    )
    for path in databases:
        try:
            connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.1)
            try:
                row = connection.execute(
                    "SELECT reasoning_effort FROM threads WHERE id = ?", (session_id,)
                ).fetchone()
                if row:
                    return row[0] if row[0] in EFFORTS else None
            finally:
                connection.close()
        except (sqlite3.Error, OSError):
            continue
    return None


def publish(payload, data_dir, codex_home):
    if not isinstance(payload, dict):
        return None
    event = payload.get("hook_event_name")
    session_id = payload.get("session_id")
    turn_id = payload.get("turn_id")
    if event not in ACTIVITIES or not isinstance(session_id, str) or not isinstance(turn_id, str):
        return None
    if not session_id or not turn_id or len(session_id) > 256 or len(turn_id) > 256:
        return None
    data_dir = Path(data_dir)
    data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Each turn owns a file. A delayed Stop for an old turn cannot clear a new one.
    identity = hashlib.sha256((session_id + "\0" + turn_id).encode()).hexdigest()
    destination = data_dir / (identity + ".json")
    effort = read_effort(session_id, codex_home)
    if effort is None and destination.exists():
        try:
            previous = json.loads(destination.read_text())
            if previous.get("effort") in EFFORTS:
                effort = previous["effort"]
        except (OSError, ValueError, AttributeError):
            pass
    snapshot = {
        "schemaVersion": 1,
        "sessionId": session_id,
        "turnId": turn_id,
        "event": event,
        "effort": effort,
        "activity": ACTIVITIES[event],
        "timestamp": time.time(),
    }
    # No prompt, tool input, assistant output, or transcript contents are copied.
    descriptor, temporary = tempfile.mkstemp(prefix=".pet-", dir=str(data_dir))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(snapshot, stream, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return snapshot


def main():
    try:
        payload = json.load(sys.stdin)
        directory = Path(os.environ.get("GPT_PET_DATA_DIR", str(Path.home() / "Library/Application Support/GPTCompanion/events")))
        codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
        snapshot = publish(payload, directory, codex_home)
        if snapshot and snapshot["event"] == "UserPromptSubmit" and os.environ.get("GPT_PET_SKIP_LAUNCH") != "1":
            app = Path(__file__).resolve().parents[1] / "app" / "GPT 桌宠.app"
            if app.is_dir():
                subprocess.Popen(
                    ["/usr/bin/open", "-g", str(app)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
    except Exception:
        # A cosmetic companion must never block a prompt or continue a completed turn.
        pass
    print("{}")


if __name__ == "__main__":
    main()

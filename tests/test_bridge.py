import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "marketplace/plugins/gpt-desktop-pet/hooks/pet_bridge.py"
spec = importlib.util.spec_from_file_location("pet_bridge", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.events = self.root / "events"
        self.codex = self.root / "codex"
        self.codex.mkdir()
        db = sqlite3.connect(self.codex / "state_5.sqlite")
        db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, reasoning_effort TEXT)")
        db.executemany("INSERT INTO threads VALUES (?, ?)", [("a", "high"), ("b", "xhigh"), ("c", "low"), ("d", "medium"), ("e", "ultra")])
        db.commit()
        db.close()

    def event(self, name, session="a", turn="1"):
        return bridge.publish({"session_id": session, "turn_id": turn, "hook_event_name": name, "prompt": "PRIVATE_PROMPT", "last_assistant_message": "PRIVATE_REPLY"}, self.events, self.codex)

    def test_effort_is_read_for_exact_session_without_copying_content(self):
        self.assertEqual(self.event("UserPromptSubmit", "a")["effort"], "high")
        self.assertEqual(self.event("UserPromptSubmit", "b")["effort"], "xhigh")
        self.assertEqual(self.event("UserPromptSubmit", "c")["effort"], "low")
        self.assertEqual(self.event("UserPromptSubmit", "d")["effort"], "medium")
        self.assertEqual(self.event("UserPromptSubmit", "e")["effort"], "ultra")
        contents = "".join(path.read_text() for path in self.events.glob("*.json"))
        self.assertNotIn("PRIVATE_PROMPT", contents)
        self.assertNotIn("PRIVATE_REPLY", contents)

    def test_stop_and_interrupt_only_end_their_own_turns(self):
        self.event("UserPromptSubmit", turn="1")
        self.event("UserPromptSubmit", turn="2")
        self.event("Stop", turn="1")
        snapshots = {json.loads(path.read_text())["turnId"]: json.loads(path.read_text()) for path in self.events.glob("*.json")}
        self.assertEqual(snapshots["1"]["activity"], "idle")
        self.assertEqual(snapshots["2"]["activity"], "thinking")
        self.assertEqual(self.event("Interrupt", turn="2")["activity"], "idle")

    def test_missing_database_does_not_invent_effort(self):
        for path in self.codex.glob("*.sqlite"):
            path.unlink()
        self.assertIsNone(self.event("UserPromptSubmit")["effort"])

    def test_hook_cli_cannot_block_codex_on_invalid_input(self):
        environment = dict(os.environ, GPT_PET_DATA_DIR=str(self.events), GPT_PET_SKIP_LAUNCH="1")
        result = subprocess.run(["/usr/bin/python3", str(SCRIPT)], input="not json", text=True, capture_output=True, env=environment)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {})
        self.assertFalse(self.events.exists())

    def test_atomic_events_are_private_and_no_temporary_files_remain(self):
        self.event("UserPromptSubmit")
        files = list(self.events.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.events.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()

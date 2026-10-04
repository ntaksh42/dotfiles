import importlib.util
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "export_orca_settings", Path(__file__).resolve().parents[1] / "Export-OrcaSettings.py"
)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ExportOrcaSettingsTests(unittest.TestCase):
    def test_exports_preferences_without_secrets_or_workspace_state(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "profile-state.db"
            output = Path(directory) / "orca/settings.json"
            with closing(sqlite3.connect(database)) as connection:
                connection.execute(
                    "CREATE TABLE profile_state_documents (domain TEXT, payload TEXT)"
                )
                connection.executemany(
                    "INSERT INTO profile_state_documents VALUES (?, ?)",
                    [
                        ("settings", json.dumps({
                            "theme": "dark", "terminalFontFamily": "日本語フォント",
                            "terminalShortcutPolicy": "orca-first",
                            "opencodeGoApiKey": "secret", "agentDefaultEnv": {"TOKEN": "secret"},
                            "workspaceDir": "C:/private", "unknownFutureSetting": "secret",
                        })),
                        ("workspaceSession", '{"history": "private"}'),
                    ],
                )
                connection.commit()
            original = database.read_bytes()
            self.assertEqual(exporter.export_settings(database, output), 3)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {
                "theme": "dark", "terminalFontFamily": "日本語フォント",
                "terminalShortcutPolicy": "orca-first",
            })
            self.assertEqual(database.read_bytes(), original)

    def test_missing_database_is_not_created(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "missing.db"
            output = Path(directory) / "settings.json"
            with self.assertRaises(sqlite3.OperationalError):
                exporter.export_settings(database, output)
            self.assertFalse(database.exists())
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

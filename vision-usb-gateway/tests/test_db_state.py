from pathlib import Path

from vision_sync.db import init_db, mark_synced, is_already_synced


def test_db_state(tmp_path: Path):
    db = tmp_path / "vision.db"
    conn = init_db(db)

    assert not is_already_synced(conn, "a.jpg", 1, 2)
    mark_synced(conn, "a.jpg", 1, 2, "/raw/a", "/bydate/a", 3)
    assert is_already_synced(conn, "a.jpg", 1, 2)
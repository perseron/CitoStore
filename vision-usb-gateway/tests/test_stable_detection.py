from pathlib import Path

from vision_sync.db import init_db, update_state


def test_stable_detection(tmp_path: Path):
    db = tmp_path / "vision.db"
    conn = init_db(db)

    stable = update_state(conn, "a.jpg", 10, 100, 1)
    assert stable == 1
    stable = update_state(conn, "a.jpg", 10, 100, 2)
    assert stable == 2
    stable = update_state(conn, "a.jpg", 11, 101, 3)
    assert stable == 1
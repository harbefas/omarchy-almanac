#!/usr/bin/env python3
"""Unit tests for almanac_fs, the descriptor-bound filesystem layer.

The races these close cannot be provoked from the shell tests: they need a
file swapped between one step and the next, which is exactly what a sync
running alongside an edit does.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))

import almanac_fs  # noqa: E402

failures = 0


def check(name, actual, expected):
    global failures
    if actual == expected:
        return
    print(f"FAIL {name}\n  expected {expected!r}\n  actual   {actual!r}", file=sys.stderr)
    failures += 1


def refuses(name, call):
    """A refusal is SystemExit with a message, not a traceback."""
    try:
        call()
    except SystemExit as exit:
        check(name, isinstance(exit.code, str), True)
        return
    check(name, "no refusal", "a refusal")


with tempfile.TemporaryDirectory() as work:
    root = Path(work)

    # ---- the walk

    (root / "real").mkdir()
    (root / "real" / "config").write_text("hello")
    check(
        "a walked read returns the file",
        almanac_fs.read_file(root / "real" / "config", "config", 1024),
        b"hello",
    )

    (root / "link").symlink_to(root / "real")
    refuses(
        "a symlinked parent is refused",
        lambda: almanac_fs.read_file(root / "link" / "config", "config", 1024),
    )

    (root / "real" / "link-to-config").symlink_to(root / "real" / "config")
    refuses(
        "a symlinked file is refused",
        lambda: almanac_fs.read_file(root / "real" / "link-to-config", "config", 1024),
    )

    refuses(
        "a path walking back up through .. is refused",
        lambda: almanac_fs.read_file(root / "real" / ".." / "real" / "config", "c", 1024),
    )

    subprocess.run(["mkfifo", str(root / "real" / "fifo")], check=True)
    refuses(
        "a fifo is refused rather than waited on",
        lambda: almanac_fs.read_file(root / "real" / "fifo", "config", 1024),
    )

    refuses(
        "an oversize file is refused",
        lambda: almanac_fs.read_file(root / "real" / "config", "config", 2),
    )

    # ---- identity, which is what makes a mutation safe to do by name

    dir_fd = almanac_fs.open_directory(root / "real")
    try:
        info = os.stat("config", dir_fd=dir_fd, follow_symlinks=False)
        check("a file is itself", almanac_fs.same_file(dir_fd, "config", info), True)

        # What a sync does: same name, different file.
        (root / "real" / "other").write_text("theirs")
        os.replace("other", "config", src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        check(
            "a swapped file is not the one that was inspected",
            almanac_fs.same_file(dir_fd, "config", info),
            False,
        )
        refuses(
            "an unlink of a swapped file is refused",
            lambda: almanac_fs.unlink_leaf(dir_fd, "config", info),
        )
        check(
            "the swapped file is still there",
            (root / "real" / "config").read_text(),
            "theirs",
        )

        # ---- writes

        info = os.stat("config", dir_fd=dir_fd, follow_symlinks=False)
        almanac_fs.write_leaf(dir_fd, "config", b"ours")
        check("a write lands", (root / "real" / "config").read_text(), "ours")
        check(
            "a write replaces the file rather than editing it",
            almanac_fs.same_file(dir_fd, "config", info),
            False,
        )
        check(
            "no temp file is left behind",
            sorted(p.name for p in (root / "real").iterdir() if ".tmp" in p.name),
            [],
        )

        info = os.stat("config", dir_fd=dir_fd, follow_symlinks=False)
        almanac_fs.unlink_leaf(dir_fd, "config", info)
        check("an unlink of the inspected file goes through",
              (root / "real" / "config").exists(), False)
    finally:
        os.close(dir_fd)

    # Two temp names in a row differ: O_EXCL only excludes anything if the
    # name could not have been guessed and created first.
    check(
        "temp names are not predictable",
        almanac_fs.temp_name("x") == almanac_fs.temp_name("x"),
        False,
    )

if failures:
    print(f"\n{failures} failing", file=sys.stderr)
    sys.exit(1)
print("almanac_fs: all checks passed")

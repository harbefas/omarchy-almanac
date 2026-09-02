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

        # ---- stamps, which are what a compare-and-swap compares
        #
        # These configs are hand-maintained. Somebody editing one in a text
        # editor while a feed is being added would otherwise have their edit
        # overwritten by a document composed from what the file said before.
        # An in-place edit keeps the inode, so identity alone does not notice.
        info = os.stat("config", dir_fd=dir_fd, follow_symlinks=False)
        before = almanac_fs.stamp(info)
        check("an untouched file still carries its stamp",
              almanac_fs.unchanged(dir_fd, "config", before), True)

        with open("config", "w", opener=lambda p, f: os.open(p, f, dir_fd=dir_fd)) as h:
            h.write("edited in place")
        check("an in-place edit is noticed even though the inode is the same",
              almanac_fs.same_file(dir_fd, "config", info), True)
        check("an in-place edit breaks the stamp",
              almanac_fs.unchanged(dir_fd, "config", before), False)

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

    # ---- the pre-rename recheck
    #
    # A stamp checked before composing the replacement and never again leaves
    # the whole write as a window. write_leaf looks once more with the new
    # contents already on disk, so only the rename is left uncovered.

    (root / "cas").mkdir()
    (root / "cas" / "config").write_text("original")
    dir_fd = almanac_fs.open_directory(root / "cas")
    try:
        before = almanac_fs.stamp(
            os.stat("config", dir_fd=dir_fd, follow_symlinks=False)
        )
        os.utime("config", ns=(0, 0), dir_fd=dir_fd)
        refuses(
            "a write is refused when the target moved on",
            lambda: almanac_fs.write_leaf(dir_fd, "config", b"mine", expected=before),
        )
        check(
            "the refused write left the newer file alone",
            (root / "cas" / "config").read_text(),
            "original",
        )
        check(
            "the refused write left no temp behind",
            [p.name for p in (root / "cas").iterdir() if ".tmp" in p.name],
            [],
        )

        now = almanac_fs.stamp(os.stat("config", dir_fd=dir_fd, follow_symlinks=False))
        almanac_fs.write_leaf(dir_fd, "config", b"mine", expected=now)
        check(
            "a write with a current stamp goes through",
            (root / "cas" / "config").read_text(),
            "mine",
        )
    finally:
        os.close(dir_fd)

    # ---- the stamp a write hands back
    #
    # A caller that wants to know later whether its own version is still in
    # place cannot stat the path to find out: by the time it looks, somebody
    # else's write may already be what it is looking at, and it would record
    # that as its own and later roll back over it.

    (root / "cas" / "installed").write_text("first")
    dir_fd = almanac_fs.open_directory(root / "cas")
    try:
        mine = almanac_fs.write_leaf(dir_fd, "installed", b"mine")
        check(
            "the write hands back the stamp of what it installed",
            almanac_fs.unchanged(dir_fd, "installed", mine),
            True,
        )
        check(
            "and that stamp describes the file that is actually there",
            mine,
            almanac_fs.stamp(
                os.stat("installed", dir_fd=dir_fd, follow_symlinks=False)
            ),
        )

        # What the rollback precondition has to survive: somebody replaces the
        # file the instant after the write returns. Stating the path here
        # would have called that edit ours.
        (root / "cas" / "theirs").write_text("theirs")
        os.replace("theirs", "installed", src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        check(
            "a stranger's write does not carry our stamp",
            almanac_fs.unchanged(dir_fd, "installed", mine),
            False,
        )
        refuses(
            "so a rollback conditional on that stamp is refused",
            lambda: almanac_fs.write_leaf(
                dir_fd, "installed", b"rolled back", expected=mine
            ),
        )
        check(
            "and the stranger's file survives",
            (root / "cas" / "installed").read_text(),
            "theirs",
        )
    finally:
        os.close(dir_fd)

    # ---- the transaction lock
    #
    # Two files cannot be renamed as one operation, so what makes the pair of
    # writes behave as one change is that no second run of this plugin is
    # inside the transaction at the same time.

    (root / "cas" / "target").write_text("x")
    holder = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import sys, time;"
            f"sys.path.insert(0, {str(Path(__file__).resolve().parent.parent / 'bin')!r});"
            "import almanac_fs;"
            f"lock = almanac_fs.lock({str(root / 'cas' / 'target')!r});"
            "lock.__enter__(); print('held', flush=True); time.sleep(30)",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        check("the other run took the lock", holder.stdout.readline().strip(), "held")
        contended = subprocess.run(
            [
                sys.executable,
                "-c",
                "import sys;"
                f"sys.path.insert(0, {str(Path(__file__).resolve().parent.parent / 'bin')!r});"
                "import almanac_fs;"
                f"lock = almanac_fs.lock({str(root / 'cas' / 'target')!r});"
                "lock.__enter__(); print('got it')",
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "ALMANAC_LOCK_TIMEOUT": "0.2"},
        )
        check("a second run is kept out", contended.returncode, 1)
        check(
            "and says so rather than waiting forever",
            "has been running for more than" in contended.stderr,
            True,
        )
    finally:
        holder.kill()
        holder.wait()

    # The lock is released with the transaction, not held to process exit.
    with almanac_fs.lock(root / "cas" / "target"):
        pass
    taken_again = subprocess.run(
        [
            sys.executable,
            "-c",
            "import sys;"
            f"sys.path.insert(0, {str(Path(__file__).resolve().parent.parent / 'bin')!r});"
            "import almanac_fs;"
            f"lock = almanac_fs.lock({str(root / 'cas' / 'target')!r});"
            "lock.__enter__(); print('got it')",
        ],
        capture_output=True,
        text=True,
    )
    check("the lock is free once the transaction ends", taken_again.stdout.strip(), "got it")

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

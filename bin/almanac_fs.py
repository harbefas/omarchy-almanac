"""Filesystem access bound to verified descriptors.

Every path this plugin touches belongs to somebody else in one sense or
another: the configs are hand-maintained, the calendar directories are written
by vdirsyncer on behalf of whoever publishes a feed. Reading or writing them
by name means the name is resolved once for the check and again for the work,
and the two can be different files.

So nothing here works on names. A path is walked one component at a time, each
opened relative to the last, and what comes back is the directory descriptor
plus the final name. Every open, create, rename and unlink after that is
relative to that descriptor, so the directory cannot be swapped underneath the
operation. Symlinks are refused at every component: a config is a file, not a
pointer to wherever something else decided to put it.

The cost of that last rule is worth stating plainly: it refuses a config
directory kept as a symlink, which is how GNU Stow and chezmoi lay out
dotfiles. Those setups have to place the real directory at the path the
plugin reads.
"""

import contextlib
import errno
import fcntl
import os
import secrets
import stat
import sys
import time

# A path deeper than this is not a config location, it is something trying to
# make the walk expensive.
MAX_PATH_COMPONENTS = 64


def die(message):
    sys.exit(message)


def _describe(error, path, label):
    if error.errno == errno.ELOOP:
        return f"{label} at {path} passes through a symlink"
    if error.errno == errno.ENOTDIR:
        return f"{label} at {path} passes through something that is not a directory"
    if error.errno == errno.ENOENT:
        return f"{label} not found at {path}"
    return f"{label} at {path} cannot be opened ({error.strerror})"


def open_dir(path, label="file"):
    """Walk to the directory holding `path`; return (dir_fd, leaf name).

    Every component is opened with O_NOFOLLOW relative to the one before it,
    so the walk cannot be redirected part of the way through and the caller
    ends up holding the directory itself rather than a name for it.
    """
    expanded = os.path.expanduser(str(path))
    # Checked before normalizing, because abspath collapses "a/../b" to "b"
    # without asking what "a" was. If it was a symlink, the collapsed path
    # names a different file than the one written down, so the caller does not
    # get to write one down.
    if ".." in [part for part in expanded.split(os.sep) if part]:
        die(f"{label} at {path} walks back up through '..'")

    absolute = os.path.abspath(expanded)
    parts = [part for part in absolute.split(os.sep) if part not in ("", ".")]
    if not parts:
        die(f"{label} at {path} is not a file")
    if len(parts) > MAX_PATH_COMPONENTS:
        die(f"{label} at {path} is nested deeper than {MAX_PATH_COMPONENTS} directories")
    dir_fd = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in parts[:-1]:
            try:
                nxt = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=dir_fd,
                )
            except OSError as error:
                die(_describe(error, path, label))
            os.close(dir_fd)
            dir_fd = nxt
    except BaseException:
        os.close(dir_fd)
        raise
    return dir_fd, parts[-1]


def open_directory(path, label="directory"):
    """Walk to the directory itself and return its descriptor.

    Same walk as open_dir, one component further: what comes back is the
    directory being worked in, so everything read or changed inside it is
    named relative to a descriptor that cannot be redirected afterwards.
    """
    dir_fd, name = open_dir(os.path.join(str(path), "."), label)
    try:
        return os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=dir_fd,
        )
    except OSError as error:
        die(_describe(error, path, label))
    finally:
        os.close(dir_fd)


def open_leaf(dir_fd, name, path, label, max_bytes):
    """Open the file itself, refusing a symlink and anything oversize."""
    # O_NONBLOCK because opening a fifo otherwise waits for a writer that is
    # never coming, and the refusal below would never be reached. On a regular
    # file, which is the only thing that gets past that check, it does nothing.
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=dir_fd,
        )
    except OSError as error:
        die(_describe(error, path, label))
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        os.close(fd)
        die(f"{label} at {path} is not a regular file")
    if info.st_size > max_bytes:
        os.close(fd)
        die(f"{label} at {path} is larger than {max_bytes} bytes")
    return fd, info


def read_fd(fd, max_bytes):
    """Everything the descriptor has, up to the ceiling."""
    chunks = []
    read_so_far = 0
    while read_so_far < max_bytes:
        chunk = os.read(fd, max_bytes - read_so_far)
        if not chunk:
            break
        chunks.append(chunk)
        read_so_far += len(chunk)
    return b"".join(chunks)


def read_file(path, label, max_bytes):
    """The file's bytes, read through a walked and verified descriptor."""
    dir_fd, name = open_dir(path, label)
    try:
        fd, _ = open_leaf(dir_fd, name, path, label, max_bytes)
        try:
            return read_fd(fd, max_bytes)
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)


def temp_name(prefix):
    """A name nothing can have guessed, so O_EXCL is a real exclusion."""
    return f".{prefix}.{secrets.token_hex(8)}.tmp"


def write_leaf(dir_fd, name, data, prefix="almanac", expected=None):
    """Replace `name` in `dir_fd` with `data`, atomically and durably.

    Written to a randomized temp created with O_EXCL in the same directory,
    fsynced, then renamed over the target with both ends of the rename
    relative to the held descriptor. The directory is fsynced after, because
    the rename is only durable once the directory recording it is.

    With `expected`, the target is checked against that stamp immediately
    before the rename rather than only before the write, so the window where
    somebody else's edit could be overwritten is the rename call itself. That
    last gap cannot be closed: POSIX has no rename that fails if the
    destination changed, and renameat2 offers NOREPLACE and EXCHANGE but
    nothing conditional on content. Serializing the whole transaction with
    lock() is what covers it against this plugin's own concurrent runs;
    against an editor that takes no lock, nothing at this layer can.

    Returns the stamp of the file this call installed, taken from the
    descriptor it wrote rather than by stating the name afterwards. A caller
    that needs to know later whether its own version is still in place has to
    be given that identity here: by the time it could stat the path, somebody
    else's write may already be the thing being stated, and it would record
    that as its own.
    """
    tmp = temp_name(prefix)
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=dir_fd,
    )
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            # Taken while the file is still held open, before it is given a
            # name anybody else can reach. The rename below changes ctime but
            # not the identity, size or mtime this records, so it describes
            # the installed file exactly.
            installed = stamp(os.fstat(handle.fileno()))
        # Re-checked here, with the new contents already on disk, so that all
        # that remains between the check and the rename is the rename.
        if expected is not None and not unchanged(dir_fd, name, expected):
            os.unlink(tmp, dir_fd=dir_fd)
            die(f"{name} changed while it was being rewritten; nothing was saved")
        os.replace(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dir_fd)
        except OSError:
            pass
        raise
    os.fsync(dir_fd)
    return installed


def stamp(info):
    """What identifies a file's contents for a compare-and-swap.

    Identity plus size plus modification time: the same file changed in place
    keeps its inode, so identity alone would not notice an edit.
    """
    return (info.st_ino, info.st_dev, info.st_size, info.st_mtime_ns)


def unchanged(dir_fd, name, before):
    """Whether `name` still carries the stamp it was read with."""
    try:
        current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return False
    return stamp(current) == before


def same_file(dir_fd, name, info):
    """Whether `name` is still the file `info` was taken from."""
    try:
        current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return False
    return current.st_ino == info.st_ino and current.st_dev == info.st_dev


def unlink_leaf(dir_fd, name, info):
    """Unlink `name`, but only while it is still the file that was inspected."""
    if not same_file(dir_fd, name, info):
        die(f"{name} changed underneath this edit and was left alone")
    os.unlink(name, dir_fd=dir_fd)
    os.fsync(dir_fd)


# How long to wait for another run of this plugin to finish a transaction
# before giving up. A deadline rather than patience, like everywhere else: a
# helper that blocks forever on a lock is a service that stays busy forever.
LOCK_SECONDS = float(os.environ.get("ALMANAC_LOCK_TIMEOUT", 10))


@contextlib.contextmanager
def lock(path, label="config"):
    """Hold an exclusive lock for a whole read-compose-write transaction.

    A compare-and-swap on each file separately still lets two runs interleave
    across the pair of them, and the check before a rename cannot be fused
    with the rename itself. Serializing the transaction is what makes the pair
    of writes behave as one, so both configs move together or neither does.

    The lock is a file beside the target rather than the target itself: taking
    it must not depend on being able to open something that a failed run may
    have left in any state, and locking a file that is replaced by rename
    would lock an inode nobody can reach afterwards.

    Advisory, so it excludes other runs of this plugin and nothing else. An
    editor writing the config takes no lock, which is what the stamp checks
    are for.
    """
    dir_fd, name = open_dir(path, label)
    fd = os.open(
        f".{name}.almanac.lock",
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC,
        0o600,
        dir_fd=dir_fd,
    )
    try:
        deadline = time.monotonic() + LOCK_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    die(
                        f"another change to {name} has been running for more "
                        f"than {LOCK_SECONDS:g}s; nothing was saved"
                    )
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
        os.close(dir_fd)

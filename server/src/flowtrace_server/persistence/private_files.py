"""Private service-owned directories; no client path or symbolic link is accepted."""

import os
import stat
from contextlib import contextmanager
from pathlib import Path


class UnsafeFilePath(OSError):
    def __init__(self):
        super().__init__("private_storage_path_invalid")


def _linked(path: Path) -> bool:
    return path.is_symlink() or path.is_junction()


def private_directory(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    for item in reversed((path, *path.parents)):
        if _linked(item):
            raise UnsafeFilePath
        if not item.exists():
            try:
                item.mkdir(mode=0o700)
            except FileExistsError:
                pass
        if _linked(item) or not item.is_dir():
            raise UnsafeFilePath
    if os.name != "nt":
        path.chmod(0o700)
    return path


def contained(path: Path, root: Path) -> None:
    try:
        relative = path.relative_to(root)
        if ".." in relative.parts:
            raise ValueError
    except ValueError:
        raise UnsafeFilePath from None
    for item in (path, *path.parents):
        if _linked(item):
            raise UnsafeFilePath
        if item == root:
            break


def regular_file(path: Path, root: Path) -> os.stat_result:
    contained(path, root)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise UnsafeFilePath
    return info


@contextmanager
def private_open(path: Path, root: Path, *, create: bool = False, append: bool = False):
    contained(path, root)
    if not create:
        regular_file(path, root)
    flags = os.O_RDWR if create or append else os.O_RDONLY
    if create:
        flags |= os.O_CREAT | os.O_EXCL
    if append:
        flags |= os.O_APPEND
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise UnsafeFilePath
        stream = os.fdopen(descriptor, "a+b" if append else "w+b" if create else "rb")
    except BaseException:
        os.close(descriptor)
        raise
    with stream:
        yield stream


def prepare_file(path: Path, root: Path) -> None:
    try:
        with private_open(path, root, create=True):
            pass
    except FileExistsError:
        regular_file(path, root)


def private_unlink(path: Path, root: Path) -> None:
    try:
        regular_file(path, root)
    except FileNotFoundError:
        return
    path.unlink()

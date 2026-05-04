#!/bin/sh
set -eu

PKG="luci-app-kidcontrol"
VERSION="1.0.0-1"
ARCH="all"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PKG VERSION ARCH ROOT_DIR

chmod 0755 "$ROOT_DIR/ipkg/CONTROL/postinst" "$ROOT_DIR/ipkg/CONTROL/prerm"
chmod 0755 "$ROOT_DIR/ipkg/etc/init.d/kidcontrol" "$ROOT_DIR/ipkg/etc/uci-defaults/99-kidcontrol-preserve"

python3 - <<'PY'
import gzip
import io
import os
import stat
import tarfile
from pathlib import Path

pkg = os.environ["PKG"]
version = os.environ["VERSION"]
arch = os.environ["ARCH"]
root = Path(os.environ["ROOT_DIR"])
ipkg = root / "ipkg"
dist = root / "dist"
dist.mkdir(parents=True, exist_ok=True)
out = dist / f"{pkg}_{version}_{arch}.ipk"


def iter_paths(base: Path):
    paths = [base]
    for current, dirs, files in os.walk(base):
        dirs.sort()
        files.sort()
        current_path = Path(current)
        for dirname in dirs:
            paths.append(current_path / dirname)
        for filename in files:
            paths.append(current_path / filename)
    return paths


def tar_gz_from(base: Path, skip_control: bool = False) -> bytes:
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
            for path in iter_paths(base):
                rel = path.relative_to(base)
                if skip_control and (rel == Path("CONTROL") or (rel.parts and rel.parts[0] == "CONTROL")):
                    continue
                name = "." if str(rel) == "." else "./" + str(rel)
                st = path.lstat()
                info = tarfile.TarInfo(name)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                info.mtime = 0
                info.mode = stat.S_IMODE(st.st_mode)
                if path.is_dir():
                    info.type = tarfile.DIRTYPE
                    info.size = 0
                    tf.addfile(info)
                elif path.is_file():
                    info.size = st.st_size
                    with path.open("rb") as f:
                        tf.addfile(info, f)
    return raw.getvalue()


control = tar_gz_from(ipkg / "CONTROL")
data = tar_gz_from(ipkg, skip_control=True)
raw = io.BytesIO()
with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
    with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, body in (
            ("./debian-binary", b"2.0\n"),
            ("./data.tar.gz", data),
            ("./control.tar.gz", control),
        ):
            info = tarfile.TarInfo(name)
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = 0
            info.mode = 0o644
            info.size = len(body)
            tf.addfile(info, io.BytesIO(body))
out.write_bytes(raw.getvalue())
print(out)
PY

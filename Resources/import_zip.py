"""Extract regular Overleaf project files into an empty staging directory."""
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
from zipfile import ZipFile

def extract(archive, destination):
    with ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > 20000 or sum(x.file_size for x in entries) > 1024**3:
            raise ValueError("ZIP exceeds the limit of 20,000 entries or 1 GiB.")
        for info in entries:
            name = info.filename
            if not (info.flag_bits & 0x800) and not name.isascii():
                raw = name.encode("cp437")
                for encoding in ("utf-8", "gb18030"):
                    try:
                        name = raw.decode(encoding)
                        break
                    except UnicodeDecodeError:
                        pass
            path = PurePosixPath(name.replace("\\", "/"))
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise ValueError("Invalid ZIP path.")
            if "__MACOSX" in path.parts or path.name == ".DS_Store":
                continue
            mode = stat.S_IFMT(info.external_attr >> 16)
            if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("Unsupported ZIP entry: " + str(path))
            target = destination.joinpath(*path.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(info) as src, target.open("xb") as dst:
                    shutil.copyfileobj(src, dst)
if __name__ == "__main__":
    try:
        extract(sys.argv[1], Path(sys.argv[2]))
    except Exception as error:
        sys.exit(str(error))

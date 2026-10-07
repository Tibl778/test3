#!/usr/bin/env python3
"""Pack a file into a 7z archive split into volumes small enough for chat uploads.

  split-7z.py <file> <out-dir> [volume-MiB]     (default 29 MiB, under a 30 MB limit)

Writes <out-dir>/<name>.7z.001, .002, ... plus SHA256SUMS for the original file.
Phone apps such as ZipXtract open the .001 file and read the rest automatically;
on a computer: `7z x <name>.7z.001`, or `cat <name>.7z.* > x.7z` and extract that.

Uses the `7z` command if installed, otherwise the py7zr Python package. 7z volumes
are a plain byte split of one archive, so the py7zr path writes one archive and cuts it.
The archive is stored without compression: an APK is already compressed.
"""

import hashlib
import os
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    vol = int(sys.argv[3]) if len(sys.argv) > 3 else 29
    name = os.path.basename(src)
    stem = name[:-4] if name.endswith(".apk") else name
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.startswith(stem + ".7z."):
            os.remove(os.path.join(out, f))
    archive = os.path.join(out, stem + ".7z")

    sevenzip = shutil.which("7z") or shutil.which("7zz") or shutil.which("7za")
    if sevenzip:
        subprocess.run([sevenzip, "a", "-mx0", f"-v{vol}m", archive, src], check=True,
                       stdout=subprocess.DEVNULL)
    else:
        try:
            import py7zr
        except ImportError:
            sys.exit("Install 7-Zip (7z) or py7zr (python3 -m pip install --user py7zr)")
        with py7zr.SevenZipFile(archive, "w", filters=[{"id": py7zr.FILTER_COPY}]) as a:
            a.write(src, name)
        size = vol * 1024 * 1024
        with open(archive, "rb") as f:
            i = 1
            while chunk := f.read(size):
                with open(f"{archive}.{i:03d}", "wb") as part:
                    part.write(chunk)
                i += 1
        os.remove(archive)

    digest = hashlib.sha256(open(src, "rb").read()).hexdigest()
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        f.write(f"{digest}  {name}\n")
    for f in sorted(os.listdir(out)):
        print(f"{os.path.getsize(os.path.join(out, f)):>12}  {f}")


if __name__ == "__main__":
    main()

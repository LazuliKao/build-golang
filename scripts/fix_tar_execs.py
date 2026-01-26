import sys
import tarfile
import tempfile
import shutil
import os

def normalize(name):
    # Remove leading "./" if present
    if name.startswith("./"):
        return name[2:]
    return name

def fix_tar(tar_path):
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".tar.gz")
    os.close(tmp_fd)
    try:
        with tarfile.open(tar_path, "r:gz") as src, tarfile.open(tmp_path, "w:gz") as dst:
            for member in src.getmembers():
                name = normalize(member.name)
                # copy member but adjust mode
                m = tarfile.TarInfo(name=member.name)
                # preserve most metadata but adjust mode
                m.uid = member.uid
                m.gid = member.gid
                m.uname = member.uname
                m.gname = member.gname
                m.mtime = member.mtime
                m.type = member.type
                # Directories -> 0755
                if member.isdir():
                    m.mode = 0o755
                    dst.addfile(m)
                elif member.isreg():
                    # Executables under go/bin and go/pkg/tool -> 0755
                    if name.startswith("go/bin/") or name.startswith("go/pkg/tool/"):
                        m.mode = 0o755
                    else:
                        m.mode = 0o644
                    f = src.extractfile(member)
                    dst.addfile(m, f)
                    if f:
                        f.close()
                else:
                    # Other types (symlinks, etc.) preserve mode if possible
                    m.mode = getattr(member, "mode", 0o644) or 0o644
                    try:
                        f = src.extractfile(member)
                    except Exception:
                        f = None
                    dst.addfile(m, f)
                    if f:
                        f.close()
        # replace original tar
        shutil.move(tmp_path, tar_path)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except Exception:
                pass

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: fix_tar_execs.py <archive.tar.gz>", file=sys.stderr)
        sys.exit(2)
    tarfile_path = sys.argv[1]
    if not os.path.exists(tarfile_path):
        print("Archive not found: %s" % tarfile_path, file=sys.stderr)
        sys.exit(2)
    try:
        fix_tar(tarfile_path)
    except Exception as e:
        print("Error fixing tar: %s" % e, file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

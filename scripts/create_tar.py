#!/usr/bin/env python3
import sys
import tarfile
import os
from pathlib import Path


def create_tar_with_permissions(source_dir, output_tar, base_name="go"):
    source_path = Path(source_dir).resolve()

    if not source_path.exists():
        print(f"Error: Source directory not found: {source_path}", file=sys.stderr)
        return False

    if not source_path.is_dir():
        print(f"Error: Source path is not a directory: {source_path}", file=sys.stderr)
        return False

    try:
        with tarfile.open(output_tar, "w:gz") as tar:
            # Add base directory entry (e.g., 'go/')
            base_dir_info = tar.gettarinfo(str(source_path), arcname=base_name)
            base_dir_info.mode = 0o755
            tar.addfile(base_dir_info)

            for root, dirs, files in os.walk(source_path):
                for dir_name in dirs:
                    dir_path = Path(root) / dir_name
                    arcname = str(Path(base_name) / dir_path.relative_to(source_path))

                    tarinfo = tar.gettarinfo(str(dir_path), arcname=arcname)
                    tarinfo.mode = 0o755
                    tar.addfile(tarinfo)

                for file_name in files:
                    file_path = Path(root) / file_name
                    arcname = str(Path(base_name) / file_path.relative_to(source_path))

                    tarinfo = tar.gettarinfo(str(file_path), arcname=arcname)

                    rel_path = file_path.relative_to(source_path)
                    parts = rel_path.parts

                    is_executable = False
                    if len(parts) >= 2 and parts[0] == "bin":
                        is_executable = True
                    elif len(parts) >= 3 and parts[0] == "pkg" and parts[1] == "tool":
                        is_executable = True
                    elif len(parts) >= 1 and parts[0] == "tools":
                        # All files under go/tools/ should be executable
                        is_executable = True

                    tarinfo.mode = 0o755 if is_executable else 0o644

                    with open(file_path, "rb") as f:
                        tar.addfile(tarinfo, f)

        output_path = Path(output_tar)
        if not output_path.exists():
            print(
                f"Error: Output tar file was not created: {output_tar}", file=sys.stderr
            )
            return False

        size_mb = output_path.stat().st_size / (1024 * 1024)
        print(f"Successfully created tar.gz: {output_tar}")
        print(f"Size: {size_mb:.2f} MB")
        return True

    except Exception as e:
        print(f"Error creating tar: {e}", file=sys.stderr)
        return False


def main():
    if len(sys.argv) != 3:
        print(
            "Usage: create_tar.py <source_go_directory> <output.tar.gz>",
            file=sys.stderr,
        )
        print(
            "Example: create_tar.py ./temp/go ./output/go1.23.5.linux-amd64.tar.gz",
            file=sys.stderr,
        )
        sys.exit(2)

    source_dir = sys.argv[1]
    output_tar = sys.argv[2]

    success = create_tar_with_permissions(source_dir, output_tar)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

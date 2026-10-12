#!/usr/bin/env python3
"""Compile and run an independent SwiftPM consumer; creates only temporary files.

Default: consume this checkout. --revision: resolve the public repository at
the specified Git revision. Requires Swift on macOS; uses only synthetic data.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Public repository commit or tag")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.revision:
        dependency = (
            '.package(name: "OpenDictation", '
            'url: "https://github.com/scshafe/open-dictation.git", '
            f'revision: {json.dumps(args.revision)})'
        )
    else:
        dependency = f'.package(name: "OpenDictation", path: {json.dumps(str(root))})'
    with tempfile.TemporaryDirectory(prefix="open-dictation-consumer-") as temporary:
        package = Path(temporary)
        (package / "Package.swift").write_text(
            '// swift-tools-version: 5.9\nimport PackageDescription\n'
            'let package = Package(name: "LibraryConsumer", '
            'platforms: [.macOS(.v14)], '
            f'dependencies: [{dependency}], '
            'targets: [.executableTarget(name: "LibraryConsumer", '
            'dependencies: [.product(name: "OpenDictationCore", '
            'package: "OpenDictation")])])\n'
        )
        source = package / "Sources/LibraryConsumer"
        source.mkdir(parents=True)
        shutil.copyfile(root / "Tests/LibraryConsumer/main.swift", source / "main.swift")
        subprocess.run(["swift", "run", "--package-path", str(package), "LibraryConsumer"], check=True)


if __name__ == "__main__":
    main()

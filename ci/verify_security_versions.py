#!/usr/bin/env python3
"""Fail an image build when security-critical Python packages regress."""

from email.parser import Parser
from importlib.metadata import PackageNotFoundError, distribution, version

from packaging.version import Version


MINIMUM_VERSIONS = {
    "lxml": "6.1.0",
    "msgpack": "1.2.1",
    "setuptools": "80.10.2",
    "wheel": "0.46.2",
}

SETUPTOOLS_VENDORED_MINIMUMS = {
    "jaraco.context": "6.1.0",
    "wheel": "0.46.2",
}


def main() -> None:
    failures = []
    for package, minimum in MINIMUM_VERSIONS.items():
        try:
            installed = version(package)
        except PackageNotFoundError:
            failures.append(f"{package} is not installed")
            continue

        if Version(installed) < Version(minimum):
            failures.append(f"{package} {installed} is older than {minimum}")
        else:
            print(f"[rocopt] {package} {installed} >= {minimum}")

    try:
        setuptools_vendor = distribution("setuptools").locate_file(
            "setuptools/_vendor"
        )
    except PackageNotFoundError:
        pass
    else:
        vendored_versions = {}
        for metadata_path in setuptools_vendor.glob("*.dist-info/METADATA"):
            metadata = Parser().parsestr(metadata_path.read_text(encoding="utf-8"))
            vendored_versions[metadata["Name"].lower()] = metadata["Version"]

        for package, minimum in SETUPTOOLS_VENDORED_MINIMUMS.items():
            installed = vendored_versions.get(package)
            if installed is None:
                failures.append(
                    f"setuptools does not expose vendored {package} metadata"
                )
            elif Version(installed) < Version(minimum):
                failures.append(
                    f"setuptools vendors {package} {installed}, older than {minimum}"
                )
            else:
                print(
                    f"[rocopt] setuptools vendors {package} {installed} >= {minimum}"
                )

    if failures:
        raise SystemExit(
            "[rocopt] vulnerable Python package versions detected:\n- "
            + "\n- ".join(failures)
        )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Fail an image build when security-critical Python packages regress."""

import sysconfig
from email.parser import Parser
from importlib.metadata import PackageNotFoundError, distribution, version
from pathlib import Path

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


def _check_ensurepip_bundled_wheels() -> list:
    """Guard against the ensurepip cleanup in dockerfile.rocm /
    docker/Dockerfile.rocm_ci regressing.

    The stdlib `ensurepip` module ships a static, never-executed bootstrap
    wheel at ensurepip/_bundled/pip-*.whl (used only by `python -m venv` /
    `python -m ensurepip`, neither of which this image runs). That wheel
    embeds pip's own pip/_vendor/vendor.txt, which pins msgpack==1.1.2 and
    names setuptools==70.3.0 as pip's internal vendored-tool versions --
    both below the floors above. Trivy's SBOM analyzer reads vendor.txt
    straight out of the wheel and reports both as vulnerable even though
    neither is actually installed or reachable. The Dockerfiles delete the
    bundled wheel(s) after copying the conda env; fail here if one is
    present so a regression is caught at build time instead of by the next
    scan.
    """
    stdlib = Path(sysconfig.get_paths()["stdlib"])
    bundled = sorted((stdlib / "ensurepip" / "_bundled").glob("*.whl"))
    return [f"stale ensurepip bootstrap wheel present: {path}" for path in bundled]


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

    failures.extend(_check_ensurepip_bundled_wheels())

    if failures:
        raise SystemExit(
            "[rocopt] vulnerable Python package versions detected:\n- "
            + "\n- ".join(failures)
        )


if __name__ == "__main__":
    main()

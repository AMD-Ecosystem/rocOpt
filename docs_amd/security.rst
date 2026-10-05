.. meta::
  :description: rocOpt security scanning policy and documented vulnerability exceptions
  :keywords: rocOpt, GPU, distributed computing, HIP, ROCm, ROCm-DS, AMD, RAPIDS, data science, security, vulnerabilities, CVE, Trivy, pip

.. _rocopt-security:

********************************************************************
Security and vulnerability exceptions
********************************************************************

rocOpt container images are scanned with `Trivy <https://trivy.dev/>`_ as part
of the release pipeline. This page lists every vulnerability finding the
rocOpt team has reviewed, where it actually comes from, and what fixes or
mitigates it.

.. important::

   Every vulnerability on this page is in a **third-party Python package
   that pip itself vendors internally** (``msgpack``, ``setuptools``,
   ``urllib3``). None of them are in rocOpt's own C++ or Python source
   code, and none are in the actual top-level packages rocOpt imports at
   runtime.

Root cause: a dormant ``ensurepip`` bootstrap wheel
=====================================================

Every stock CPython 3.13 install bundles a dormant ``ensurepip`` bootstrap
wheel at
``/root/miniforge3/envs/cuopt_dev/lib/python3.13/ensurepip/_bundled/pip-26.2.1-py3-none-any.whl``,
used only by ``python -m venv`` / ``python -m ensurepip`` — neither of which
rocOpt's image ever runs. That wheel bundles pip's own private, vendored
copies of several packages under ``pip/_vendor/`` (including ``msgpack`` and
``urllib3``) and references a ``setuptools`` version as plain text in
``pip/_vendor/vendor.txt``. Trivy's SBOM scanner reads those old pinned
versions out of the dormant wheel and reports them as if they were the
packages rocOpt actually uses — even though the real, importable top-level
packages are already newer: ``msgpack`` 1.2.1, ``setuptools`` 80.10.2
(conda ``setuptools`` 84.0.0), ``urllib3`` 2.8.0.

The rocOpt team root-caused and fixed this for the ``msgpack``/``setuptools``
findings by stripping the dormant wheel from both the builder and runtime
Dockerfile stages. The two ``urllib3`` findings are advisories published
2026-09-29, against the same vendored copy inside that same wheel, and the
existing fix is expected to cover them too — pending confirmation on the
next image rebuild and rescan.

Scope and process
==================

- **Scanner:** Trivy, run against the published container image on every
  release.
- **What's scanned:** OS packages (Ubuntu), conda/pip packages in the
  ``cuopt_dev`` environment, and Node packages — not rocOpt's own source
  tree.
- **Exception mechanism:** findings pending rebuild confirmation are
  suppressed in CI with a
  `.trivyignore <https://github.com/ROCm-DS/rocOpt/blob/main/.trivyignore>`_
  file. Every entry there has a matching write-up in
  `VULNERABILITY_EXCEPTIONS.md <https://github.com/ROCm-DS/rocOpt/blob/main/VULNERABILITY_EXCEPTIONS.md>`_,
  the engineering source of truth for this page.
- **Review cadence:** each exception is reviewed against a freshly rebuilt
  image; once confirmed fixed, the exception is removed rather than
  renewed.

Current findings
===================

.. list-table::
   :header-rows: 1
   :widths: 16 14 10 20 20 20

   * - Package (pip-vendored)
     - CVE / advisory
     - Severity
     - Flagged version
     - Fix status
     - Review by
   * - msgpack
     - `GHSA-6v7p-g79w-8964 <https://github.com/advisories/GHSA-6v7p-g79w-8964>`_
     - High (7.5)
     - 1.1.2
     - Fixed in source; confirm on next rebuild
     - 2026-10-15
   * - setuptools
     - `CVE-2025-47273 <https://avd.aquasec.com/nvd/cve-2025-47273>`_
     - High (8.8)
     - 70.3.0
     - Fixed in source; confirm on next rebuild
     - 2026-10-15
   * - urllib3
     - `CVE-2026-97687 <https://avd.aquasec.com/nvd/cve-2026-97687>`_
     - High (7.6)
     - 2.7.0
     - Same fix should apply; unverified
     - 2026-10-15
   * - urllib3
     - `CVE-2026-97689 <https://avd.aquasec.com/nvd/cve-2026-97689>`_
     - High (8.9)
     - 2.7.0
     - Same fix should apply; unverified
     - 2026-10-15

msgpack — GHSA-6v7p-g79w-8964
==============================

**Issue:** reusing a MessagePack ``Unpacker`` after a caught error can crash
the process (segmentation fault), a denial-of-service risk if untrusted
input is fed to a reused ``Unpacker``. Fixed upstream in pip package
``msgpack`` 1.2.1.

**Where it's from:** pip's internal vendored copy inside the dormant
``ensurepip`` wheel — not the ``msgpack`` rocOpt actually imports.

**Customer action:** none required for this finding. If you independently
use ``msgpack`` in code built on top of rocOpt, don't reuse an ``Unpacker``
after it errors — create a new one per decode.

setuptools — CVE-2025-47273
============================

**Issue:** path traversal in ``setuptools``' ``PackageIndex`` before 78.1.1 —
a crafted package index can write files anywhere the Python process can
write. Fixed upstream in pip package ``setuptools`` 78.1.1.

**Where it's from:** a version string referenced inside the dormant
``ensurepip`` wheel — not the ``setuptools`` rocOpt actually has installed.

**Customer action:** none required for this finding. If you install
additional packages into the image yourself, only use trusted, pinned
indexes.

urllib3 — CVE-2026-97687 (proxy TLS override)
================================================

**Issue:** target-server TLS settings (for example ``cert_reqs=CERT_NONE``)
leak onto the HTTPS proxy connection, which can let traffic routed through
an HTTPS proxy be intercepted. Fixed upstream in pip package ``urllib3``
2.8.0.

**Where it's from:** pip's internal vendored copy inside the same dormant
``ensurepip`` wheel — not the ``urllib3`` rocOpt actually imports.

**Customer action:** none required for this finding. If you route your own
traffic through an HTTPS proxy, keep TLS verification on for both the proxy
and the target server.

urllib3 — CVE-2026-97689 (unbounded chunk-parser memory)
============================================================

**Issue:** ``HTTPResponse.read_chunked`` buffers a chunked-transfer-encoding
chunk-size line with no length limit, so a malicious server can exhaust
process memory. Fixed upstream in pip package ``urllib3`` 2.8.0.

**Where it's from:** same dormant-wheel vendored copy as above.

**Customer action:** none required for this finding. If you independently
make HTTP calls to untrusted servers, front them with a size-limiting proxy
or timeout.

.. note::

   This page reflects findings as of the dates in the table above. To
   report a new security issue, see
   `Security reporting <https://github.com/ROCm-DS/rocOpt/blob/main/.github/SECURITY.md>`_
   rather than filing a public GitHub issue.

# Version 0.1.1 release record

Status: [published to PyPI](https://pypi.org/project/dynatroni/0.1.1/) on
2026-10-15 and verified with a fresh installation.

Release commit: `4395045ed1da8cff1f1c4f42e88fb544e2dbc89f` on `v0.1.1`.
Publication tag: `pypi-0.1.1`.
[Release CI](https://github.com/SoftOboros/dynatroni/actions/runs/38812320060)
passed all seven jobs, and the
[Publish workflow](https://github.com/SoftOboros/dynatroni/actions/runs/38812455073)
succeeded, including verification of both release artifacts.

The package installs a discovery adapter for issue #2 and requires Patroni 3.3.0
or later. The backend implementation and its cluster behavior are unchanged.
See the [changelog](../CHANGELOG.md) and [user quickstart](install.md).

## Verification

- Build both artifacts with `python -m build`.
- Both local release artifacts passed `twine check`.
- Install a wheel and a source distribution normally; run
  `python -I tests/test_installed_discovery.py` against each installation.
- CI covers Python 3.9, 3.12, and 3.14 with the current compatible Patroni,
  plus Patroni 3.3.0 on Python 3.9. It runs on `main` and `v0.1.1`.
- Local checks passed with Patroni 4.1.5 on Python 3.12 (source distribution)
  and 3.14 (wheel), and Patroni 3.3.0 on Python 3.11 (wheel).
- Upgrading the previous 0.1.0 installation with its manually copied backend
  passed the same discovery and construction checks.
- Removing the adapter caused the regression tests to fail; restoring it
  returned them to green.
- Uninstalling Dynatroni removed the adapter and preserved hashes of all 72
  Patroni-owned files in the Python 3.14 environment; reinstalling passed again.
- Both Packer templates passed syntax validation. No AMI build or live AWS
  cluster verification was performed.

## Published installation verification

A new Python 3.14.4 virtual environment installed `dynatroni==0.1.1` and
`patroni[psycopg3]` with pip's isolated mode, an explicit public PyPI index,
and `--no-cache-dir`. It resolved Patroni 4.1.5. The installed distribution
reported 0.1.1, and both its implementation and adapter loaded from that fresh
environment. The installed-artifact regression tests, `pip check`, and
`patroni --version` passed. AWS clients were mocked for DCS construction;
no live cluster operation was tested.

The pip installation report's wheel URL and SHA-256 matched PyPI's metadata.
PyPI listed both artifacts as available and not yanked:

| Artifact | SHA-256 |
| --- | --- |
| `dynatroni-0.1.1-py3-none-any.whl` | `91c292a038e6ecde0c5ee72914d7523ade06c1197d115c19309d254dd626af07` |
| `dynatroni-0.1.1.tar.gz` | `9145d7efe342e05cac07df605b4c1a9694fa7a1f65e5601d2ee069a796810351` |

## Publication procedure

1. Review the branch and its CI results. Confirm the intended release commit
   and that version 0.1.1 has not already been published to the destination index.
2. When release publication is authorized, use the existing Publish workflow
   against the selected commit. Its tag trigger is `pypi-0.1.1`; `v0.1.1` is the
   preparation branch, not a publication trigger. Manual workflow dispatch also
   publishes and must be treated as a release action.
3. The Publish workflow builds and verifies both artifacts before uploading.
   Verify PyPI readback and a fresh installation of `dynatroni==0.1.1` after upload.
4. Mark the changelog as released, update the quickstart's prerelease wording,
   and post the [prepared issue response](../.github/issue-2-response.md) with its
   publication status updated to match the actual release.
5. Build AMIs only after the package is available from PyPI. The templates now
   use package-managed discovery and check it before continuing.

The [updated response was posted to issue #2](https://github.com/SoftOboros/dynatroni/issues/2#issuecomment-6202991496)
after PyPI readback and fresh-install verification. Its body was read back and
matched the committed response text. Issue #2 remains open for reporter
validation or a maintainer decision.

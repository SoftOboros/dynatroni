# Version 0.1.1 release preparation

Status: prepared on branch `v0.1.1`; PyPI publication is pending.

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

## Publication steps

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

Issue #2 remains open until reporter validation or a maintainer decision.

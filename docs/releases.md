# Preparing a release

[v0.1.0](https://github.com/salilchincholikar/bridge/releases/tag/v0.1.0) is an Apple Silicon developer preview with an ad-hoc-signed, unnotarized app ZIP. The owner selected Apache-2.0; LICENSE and NOTICE are included in app bundles. Local ad-hoc signing verifies bundle integrity; it does not establish Developer ID identity, notarization or trust on another Mac.

## Source preview gate

- Resolve security findings with regression evidence and review remaining threat-model limits.
- Complete the provenance review for all included code/assets and retain the adopted license and required notices.
- Review the exact intended source manifest: exclude personal configuration, generated captures/binaries and unreviewed experiments. Scan contents, not just filenames/ignore rules.
- Reproduce build/offline checks from a fresh checkout; verify actual CI after connecting the repository.
- Maintainer follow-up: configure the optional private security-reporting route and realistic support policy; the owner is handling this separately from the initial source push.
- Review optional assistant support, including current provider configuration/tool isolation and terms. Do not infer compatibility from fake-harness checks.
- Use only fictional data in public screenshots; perform native visual/accessibility review rather than publishing incomplete offscreen captures.

## Unnotarized developer preview

The owner authorized an Apple Silicon 0.1.0 preview with explicit ad-hoc signing and notarization limitations. The tag-triggered `release.yml` runs offline checks, packages only the production bundle and legal/setup files, verifies the extracted ZIP and publishes a GitHub prerelease with checksums and a manifest. This preview does not satisfy the signed-distribution gates below. Broader real-account, minimum-OS and quarantined-download acceptance remain open.

Build and validate locally with `make check`, commit the release sources, then run `python3 scripts/package-preview.py` from the clean checkout. Publish by pushing the matching `v` version tag after reviewing its release notes. Never move an existing public release tag. A failed publish may leave a draft for maintainer review; no existing release is overwritten automatically.

## Signed downloadable app gate

In addition to the source gate:

- Confirm repository name, bundle identifier, version/build numbering and supported architectures/macOS versions.
- Build production separately from demo/UI harness; run `make verify-bundle` and inspect the entire artifact manifest.
- Use a deliberate Developer ID signing/notarization/stapling workflow with controlled signing credentials. Verify a fresh quarantined download with Gatekeeper on another supported machine.
- Verify representative AWS workflows with explicitly selected test accounts, including expired sign-in, denied access and missing CLI. Do not import unsanitized responses as fixtures.
- Produce reviewed release notes, checksums, license/notices and a reproducible package manifest. Test upgrade/configuration behavior.

The ordinary checks workflow has read-only repository access. The separate preview-release workflow has repository write permission for release creation and no Apple signing certificates or live AWS/provider credentials. Apple signing setup, automatic updates and Homebrew distribution remain future work.

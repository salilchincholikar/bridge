# Preparing a release

There is no published release yet. The owner selected Apache-2.0; LICENSE and NOTICE are included in app bundles. Local ad-hoc signing verifies bundle integrity; it does not establish Developer ID identity, notarization or trust on another Mac.

## Source preview gate

- Resolve security findings with regression evidence and review remaining threat-model limits.
- Complete the provenance review for all included code/assets and retain the adopted license and required notices.
- Review the exact intended source manifest: exclude personal configuration, generated captures/binaries and unreviewed experiments. Scan contents, not just filenames/ignore rules.
- Reproduce build/offline checks from a fresh checkout; verify actual CI after connecting the repository.
- Maintainer follow-up: configure the optional private security-reporting route and realistic support policy; the owner is handling this separately from the initial source push.
- Review optional assistant support, including current provider configuration/tool isolation and terms. Do not infer compatibility from fake-harness checks.
- Use only fictional data in public screenshots; perform native visual/accessibility review rather than publishing incomplete offscreen captures.

## Downloadable app gate

In addition to the source gate:

- Confirm repository name, bundle identifier, version/build numbering and supported architectures/macOS versions.
- Build production separately from demo/UI harness; run `make verify-bundle` and inspect the entire artifact manifest.
- Use a deliberate Developer ID signing/notarization/stapling workflow with controlled signing credentials. Verify a fresh quarantined download with Gatekeeper on another supported machine.
- Verify representative AWS workflows with explicitly selected test accounts, including expired sign-in, denied access and missing CLI. Do not import unsanitized responses as fixtures.
- Produce reviewed release notes, checksums, license/notices and a reproducible package manifest. Test upgrade/configuration behavior.

The prepared CI intentionally has no publish job, signing certificates or live credentials. Repository creation/publishing and Apple signing setup happen later with the owner. Automatic updates and Homebrew distribution follow a reliable initial release path.

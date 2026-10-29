# Licensing and attribution

The owner selected **Apache-2.0** on 2026-10-29. The repository's [LICENSE](../LICENSE) contains the full terms. [NOTICE](../NOTICE) credits Salil Chincholikar for Bridge and retains attribution for build-script material adapted from Waffle.

The bundle script includes LICENSE and NOTICE in production, demo and UI-check bundles. The production verification script compares their contents with the repository copies. Contributions submitted for inclusion use the same license, subject to a separate written agreement; see CONTRIBUTING.md and Apache-2.0 section 5.

## Provenance reviewed so far

- `Makefile` and `scripts/bundle.sh` explicitly identify their Waffle adaptation. The neighboring Waffle project's LICENSE is Apache-2.0; its NOTICE names Salil Chincholikar and Waffle contributors. Bridge retains that attribution and the adaptation comments.
- The Swift package currently has no third-party SwiftPM dependencies. Recheck dependency licenses/notices when packages are introduced.
- Icon generation source is retained in `scripts/generate-icon.swift`.

This is not a complete ownership clearance for every file. Finish reviewing the exact intended initial source manifest, fixtures/assets and historical experiments before publication. Do not copy unrelated third-party notices merely because they occur in Waffle's broader dependency inventory; retain the notices applicable to material actually included in Bridge.

Public screenshots must use fictional demo data. Unreviewed experiments and generated development artifacts are not automatically cleared for public import. See [release preparation](releases.md).

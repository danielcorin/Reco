# Contributing

Thanks for helping improve Reco.

1. Open an issue before starting a large behavioral or architectural change.
2. Keep the app focused: local dictation, a global shortcut, and a minimal menu bar interface.
3. Do not commit Apple Team IDs, provisioning profiles, signing certificates, model weights, recordings, archives, or build output.
4. Install the repository's formatting hook once per checkout with `scripts/install-git-hooks.sh`. The hook runs Apple's Xcode-provided `swift-format` on staged Swift files and re-stages them before each commit. Run `scripts/format-swift.sh` to format all tracked Swift files manually.
5. Build the Reco scheme with signing disabled before opening a pull request.
6. Describe permission, privacy, model, or dependency-license changes explicitly in the pull request.

Unless stated otherwise, contributions submitted to this project are licensed under Apache-2.0, the repository's license.

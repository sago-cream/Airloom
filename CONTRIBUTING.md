# Contributing

Open a pull request from a focused branch. Use Conventional Commits for meaningful batches; `style` is reserved for formatting, not visual or CSS changes. Branch names follow `<type>/<kebab-case-description>`, such as `fix/menu-dismissal` or `docs/import-guide`.

Airloom follows the PR rules used by Comux and Sago Drop:

- Changes to `main` require a PR and the passing `test` check from GitHub Actions, with the branch up to date.
- Resolve review conversations before merging. Zero approvals are required so a solo maintainer can merge a reviewed PR.
- Use squash merges and a Conventional Commit PR title. Force pushes and deletion of `main` are blocked, including for administrators.
- Version tags matching `v*` cannot be moved or deleted.

The active repository rules are recorded in [.github/rulesets](.github/rulesets). Repository administrators apply settings changes through GitHub; editing the JSON alone does not change the live rules.

Run the same checks as CI before opening a PR:

```sh
zsh Scripts/test.sh --menu
UNIVERSAL=1 zsh Scripts/build.sh
python3 Scripts/check-bundle.py build/Airloom.app
bash -n Scripts/release.sh
zsh -n Scripts/build.sh Scripts/install.sh Scripts/test.sh
```

The menu tests exercise AppKit and require an active macOS desktop. Import, timeline, memory, and screen-saver integration checks are documented in [Docs/Development.md](Docs/Development.md). Do not lock or sleep someone else's Mac as part of an unattended test.

For distribution changes, run `python3 -m unittest discover -s Tests -p 'test_*.py'` and `actionlint`. Validate generated Ruby syntax with `ruby -c path/to/airloom.rb` and run `brew style --cask sago-cream/tap/airloom` from a recognized tap; use the Homebrew publisher's dry-run mode before updating the shared tap. Never commit release credentials, private keys, user videos, or personal settings.

Use the PR template to explain the user-facing result and relevant verification. Keep implementation details in the description only when they help review the change. Release publication and tap updates are described in [Docs/Releasing.md](Docs/Releasing.md).

# Release Automation

Releases are Cabal-owned. The package version in
`amaru-treasury-tx.cabal` is the product version; there is no
release-please manifest and no separate `version.txt`.

## Main-branch planner

Every push to `main` runs the Release Planner workflow. It reads
Conventional Commit messages since the last `v*` tag and either:

- opens or updates `release/cabal-release` with a Cabal version bump
  and a generated `CHANGELOG.md` section;
- creates the release tag if the just-merged release PR already
  contains a changelog section for the current Cabal version;
- exits without changes when there are no releasable commits.

The planner maps commit intent onto PVP-shaped Cabal versions:

| Commit signal | Cabal bump |
| :------------ | :--------- |
| `fix:` / `perf:` | fourth component, for example `0.1.1.0` to `0.1.1.1` |
| `feat:` | third component, for example `0.1.1.0` to `0.1.2.0` |
| `!` or `BREAKING CHANGE:` | second component, for example `0.1.1.0` to `0.2.0.0` |

For user-facing CLI changes that invalidate old operator scripts, use
a breaking Conventional Commit such as `feat!:` and include a
`BREAKING CHANGE:` footer. The release planner treats either marker as
a breaking release signal.

The planner must push branches and tags through `RELEASE_BOT_SSH_KEY`.
Using the default `GITHUB_TOKEN` for git writes would create branch and
tag events that do not trigger the normal CI and publication workflows.

## One-time setup

Create a dedicated write deploy key and store the private half as a
repository secret. This is repo-scoped and does not require a personal
access token.

```bash
tmpdir="$(mktemp -d)"
ssh-keygen -t ed25519 \
  -C 'amaru-release-bot@lambdasistemi/amaru-treasury-tx' \
  -f "$tmpdir/amaru-release-bot" \
  -N ''

gh api repos/lambdasistemi/amaru-treasury-tx/keys \
  -f title='amaru-release-bot' \
  -f key="$(cat "$tmpdir/amaru-release-bot.pub")" \
  -F read_only=false

gh secret set RELEASE_BOT_SSH_KEY \
  --repo lambdasistemi/amaru-treasury-tx \
  --body "$(cat "$tmpdir/amaru-release-bot")"

rm -rf "$tmpdir"
gh secret list --repo lambdasistemi/amaru-treasury-tx \
  | grep '^RELEASE_BOT_SSH_KEY'
gh api repos/lambdasistemi/amaru-treasury-tx/keys \
  --jq '.[] | select(.title == "amaru-release-bot")'
```

The deploy key must have write access. A read-only key can fetch the
repository but cannot push the release branch or release tag.

## Publication

Merging the release PR does not publish directly. The next planner run
creates `v<package-version>`, and the tag push starts the Linux and
Darwin release workflows.

Before merging a release-bound PR, run:

```bash
nix develop --quiet -c just ci
```

That includes `just smoke`, which exercises the swap-wizard signer
regression and checks that the built CLI advertises
`--extra-signer,--signer SCOPE|HEX`.

The release workflows run `scripts/release/check-version-consistency`
before building. A tag is publishable only when:

- the tag version matches `amaru-treasury-tx.cabal`;
- `CHANGELOG.md` contains a section for that version;
- release-please state files are absent.

Linux publishes AppImage, DEB, and RPM assets. Darwin publishes an
aarch64-darwin tarball and updates the Homebrew tap. Each release
bundle is smoke-tested by extracting the artifact and checking the
`swap-wizard --help` signer surface before upload.

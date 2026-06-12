# Building & signing Lineup

Lineup ships as a Developer ID–signed, notarized, stapled `Lineup.app` (wrapped
in a DMG). The signing pipeline reuses Cleyrop's existing macOS signing
infrastructure — the same self-hosted Mac runner and the same Apple credentials
already used to sign the Cleyrop CLI (`cleyrop-sdk`).

## Local build (unsigned)

```sh
./scripts/build-macos.sh            # -> build/Build/Products/Release/Lineup.app
```

No Apple account or cert needed; the app runs locally but other Macs will show a
Gatekeeper warning until it is signed + notarized.

## Signing locally (optional)

Export the six Apple credentials into your shell (see the table below), then:

```sh
./scripts/build-macos.sh
./scripts/sign-and-notarize-macos.sh   # signs + notarizes + staples the .app
./scripts/package-dmg-macos.sh         # -> dist/Lineup-<version>.dmg, also signed + notarized + stapled
```

The signing identity is **`Developer ID Application: Cleyrop (4SKW2Z97A2)`**.

Both scripts share the keychain/notary plumbing in
`scripts/lib/apple-codesign.sh`, so the app **and** the DMG are each Developer ID
signed, notarized and stapled. With no credentials present (and `STRICT=0`) both
steps skip signing and emit an unsigned artifact with a warning.

## CI

The repo lives on **GitHub** (`cleyrop/Lineup`) and ships via **GitHub Actions**
on GitHub-hosted macOS runners (`macos-15` — Xcode, `codesign` and `notarytool`
preinstalled, fresh isolated VM per job):

- **`.github/workflows/ci.yml`** — on push to `main` and on PRs: build + unit /
  integration tests + an unsigned Release build smoke. No signing.
- **`.github/workflows/release.yml`** — on tag `vX.Y.Z`: test → build → sign →
  notarize → staple → package + sign + notarize the DMG → publish a GitHub
  Release with the DMG attached. It sets `STRICT=1`, so a missing/partial
  credential set fails the release instead of silently shipping unsigned.

The version is derived from the tag (`v1.2.3` → `MARKETING_VERSION=1.2.3`) and the
build number from `github.run_number`.

> A `.gitlab-ci.yml` is also kept for running the *same* scripts on Cleyrop's
> self-hosted Mac runner (it shares the `macos-signing` resource group with the
> SDK). It's an alternative, not the primary path — GitHub ignores it and GitLab
> ignores `.github/`, so the two coexist harmlessly. Use it only if you mirror to
> GitLab to avoid GitHub-hosted macOS minutes.

## Required secrets

The six Apple credentials must be available to the release job. Add them as
**GitHub repository secrets** on `cleyrop/Lineup` (or organisation secrets so the
SDK and any other project inherit them):

| Secret | Contents |
|---|---|
| `APPLE_DEVELOPER_ID_APPLICATION_P12` | base64 `.p12` — Developer ID Application cert + private key |
| `APPLE_DEVELOPER_ID_PASSWORD` | `.p12` export password |
| `APPLE_TEAM_ID` | `4SKW2Z97A2` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_KEY_ISSUER` | API key issuer UUID |
| `APPLE_NOTARY_KEY_P8` | base64 `.p8` private key |

The same values already exist as GitLab variables on `apps/internal` (used by
`cleyrop-sdk`). Reuse them. Set each on GitHub with `gh` (reads the value from a
file or stdin so it never lands in shell history):

```sh
gh secret set APPLE_TEAM_ID --repo cleyrop/Lineup --body "4SKW2Z97A2"
gh secret set APPLE_DEVELOPER_ID_APPLICATION_P12 --repo cleyrop/Lineup < developer_id.p12.base64
gh secret set APPLE_NOTARY_KEY_P8 --repo cleyrop/Lineup < notary_key.p8.base64
# ...repeat for APPLE_DEVELOPER_ID_PASSWORD, APPLE_NOTARY_KEY_ID, APPLE_NOTARY_KEY_ISSUER
```

The `.p12` and `.p8` secrets are the **base64** of the binary files (the scripts
`base64 --decode` them), e.g. `base64 -i cert.p12 -o developer_id.p12.base64`.

The two `scripts/AppleDeveloperID*.cer` files are the public Apple intermediate
CAs (not secrets); they are committed so the leaf chains to the Apple Root on the
runner regardless of which intermediate signed it.

## Cutting a release

```sh
git tag v1.0.0
git push origin v1.0.0     # triggers release.yml -> signed DMG on the Releases page
```

## Homebrew tap

The app is distributed via the Cleyrop tap [`cleyrop/homebrew-lineup`](https://github.com/cleyrop/homebrew-lineup):

```sh
brew install --cask cleyrop/lineup/lineup
```

`release.yml`'s final step bumps that tap's `Casks/lineup.rb` (version + DMG
`sha256`) automatically on every stable tag. It authenticates with a
**write-enabled deploy key** scoped to the tap repo — the public half is a
read-write deploy key on `cleyrop/homebrew-lineup`, the private half is the
`HOMEBREW_TAP_DEPLOY_KEY` secret on `cleyrop/Lineup` (both already provisioned).
If the secret is absent the step is skipped (the release still publishes, the
cask just won't auto-bump). Prerelease tags (`v1.2.3-rc1`) are skipped so the
cask only tracks stable releases.

A deploy key is used rather than a personal access token because it is scoped to
exactly one repo and can be provisioned entirely from the CLI. To rotate it:

```sh
ssh-keygen -t ed25519 -f tapkey -N "" -C "lineup-release-autobump"
gh repo deploy-key add tapkey.pub --repo cleyrop/homebrew-lineup --allow-write --title "lineup-release-autobump (CI write)"
gh secret set HOMEBREW_TAP_DEPLOY_KEY --repo cleyrop/Lineup < tapkey
rm -P tapkey tapkey.pub
```

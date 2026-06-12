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
./scripts/sign-and-notarize-macos.sh
./scripts/package-dmg-macos.sh      # -> dist/Lineup-<version>.dmg
```

The signing identity is **`Developer ID Application: Cleyrop (4SKW2Z97A2)`**.

## CI

`.gitlab-ci.yml` runs the build on the runner tagged `macos`:

- **branches / MRs** → `build:macos` produces an unsigned app for verification.
- **tags `vX.Y.Z`** → `release:macos` builds + signs + notarizes + staples + packages
  the DMG. It sets `STRICT=1`, so a missing/partial credential set fails the
  release instead of silently shipping an unsigned app.

`resource_group: macos-signing` serializes Lineup's signing job with the SDK's —
they share one Mac runner and each mutate the user keychain search list.

### Where CI runs — GitHub vs GitLab

The source repo lives on **GitHub** (`cleyrop/Lineup`), but the Apple
credentials and the `macos` runner live on **GitLab** (`cleyrop-org`, project
`apps/internal`). To get signed builds, the tag pipeline must run on GitLab. Two
options:

1. **Push-mirror** `cleyrop/Lineup` → a GitLab project under `cleyrop-org` and
   let GitLab CI run `.gitlab-ci.yml` on tags. (Recommended — keeps GitHub as the
   public/upstream-tracking home.)
2. Move the repo to GitLab outright.

Either way the `.gitlab-ci.yml` here is ready to run unchanged.

## Required CI variables

These six variables must be available to the signing job — provision them on the
Lineup GitLab project, or once at the **`cleyrop-org` group level** so every
project (including this one and the SDK) inherits them. All masked + protected.

| Variable | Contents |
|---|---|
| `APPLE_DEVELOPER_ID_APPLICATION_P12` | base64 `.p12` — Developer ID Application cert + private key |
| `APPLE_DEVELOPER_ID_PASSWORD` | `.p12` export password |
| `APPLE_TEAM_ID` | `4SKW2Z97A2` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_KEY_ISSUER` | API key issuer UUID |
| `APPLE_NOTARY_KEY_P8` | base64 `.p8` private key |

The values already exist as project-level variables on `apps/internal` (used by
`cleyrop-sdk`). Reuse those exact values. To copy a single one into the Lineup
project with `glab`:

```sh
glab variable set APPLE_TEAM_ID "4SKW2Z97A2" -R cleyrop-org/Lineup --masked --protected
# ...repeat for each, pulling values from the apps/internal project or a secret store.
```

The two `scripts/AppleDeveloperID*.cer` files are the public Apple intermediate
CAs (not secrets); they are committed so the leaf chains to the Apple Root on the
runner regardless of which intermediate signed it.

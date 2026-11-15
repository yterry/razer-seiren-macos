# Security policy

## Supported versions

Only the latest release receives security fixes.
If you run an older version, update to the latest release before reporting, and check whether the problem is still there.

## Reporting a vulnerability

Please report security problems privately through GitHub.
Open the repository's **Security** tab and select **Report a vulnerability**, or go straight to [the private report form](https://github.com/yterry/razer-seiren-macos/security/advisories/new).
Only the maintainers can see what you send there.

Please do not open a public issue, pull request or discussion about a security problem.

## What to include

- The app version, shown in the 🎙 menu as "Seiren X.Y.Z".
- The macOS version.
- How you installed the app: Homebrew, the downloaded zip, or a build from source.
- Steps to reproduce the problem.
- What an attacker gains, for example running code as root, reading the microphone without permission, or changing what the app downloads or installs.

## Scope

In scope:

- The Seiren menu bar app.
- The Seiren FX audio driver.
- The install and packaging scripts in `scripts/` and the Homebrew cask in `packaging/`.
- The release workflow in `.github/workflows/release.yml`.

Out of scope:

- The microphone's own firmware.
- Bugs in the vendored RNNoise sources in `Sources/RNNoise` that this app's use of RNNoise cannot reach.

## What to expect

We acknowledge every report within 7 days.
When a fix ships, we credit you in its release notes unless you prefer not to be named.

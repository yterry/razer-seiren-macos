# Homebrew tap

The Homebrew cask is **not kept in this repo**. Its single source of truth is the
tap repo — that is what `brew` installs from, and what release CI bumps
automatically on each tagged release:

- **Tap:** <https://github.com/yterry/homebrew-tap> → `Casks/razer-seiren.rb`

## Install

```sh
brew tap yterry/tap
brew install --cask razer-seiren
```

A copy used to live here as a "reference snapshot," but it inevitably drifted from
the tap (release CI bumps the tap, not this repo), so it was removed to keep one
source of truth. See the **Update Homebrew tap** step in
[`.github/workflows/release.yml`](../../.github/workflows/release.yml) for the
automation, and the tap repo's `scripts/bump-cask.sh` for the manual path.

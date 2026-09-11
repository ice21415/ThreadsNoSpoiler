# Threads No Spoiler

Rootless Theos scaffold for the extracted Threads build (`com.burbn.barcelona`). It injects only into Threads and adds a **Spoiler Bypass** entry to a recognised Settings screen. The preference is stored under two `NSUserDefaults` keys prefixed with `TSB`.

## Behaviour

- **Automatically reveal spoilers** is enabled by default.
- The tweak dynamically finds loaded classes whose names contain `BCNSpoilerView`.
- On `didMoveToWindow`, it hides descendant views whose runtime class name contains `spoiler` and `mask`, `overlay`, or `blur`.
- It does not modify API responses, post data, authentication, or server state.

This heuristic follows the static evidence in this bundle (`BCNSpoilerView`, `BCNSpoilerMaskingView`, `isSpoilerMaskVisible`, and `spoilerRevealHandler`). Threads may rename or restructure these views in future releases; turn on **Debug logging**, relaunch Threads, and inspect the device log before expanding the hook.

## Build

Run this on a macOS or Linux Theos environment with an iOS SDK and a rootless jailbreak toolchain:

```sh
cd ThreadsNoSpoiler
make package
```

The resulting Debian package belongs on a jailbroken test device. In this Windows workspace, build using the installed WSL distribution and its Linux filesystem (required for signing):

```powershell
wsl -d Ubuntu-Theos -u theos -- bash scripts/build-package.sh
wsl -d Ubuntu-Theos -- bash scripts/update-repository.sh packages/com.example.threadsnospoiler_0.1.39_iphoneos-arm64.deb
```

The repository script retains previous packages and regenerates the APT indexes and checksums.

## Scope

The badge sits at the trailing edge of the native post action row, to the right
of the paper-plane share button. Header text, icons, transforms, row heights and
native controls are left unchanged.
See [the footer placement audit](docs/footer-layout-audit.md) for bundle evidence,
layout behavior, and outstanding device checks. Run its geometry tests with:

```powershell
wsl -d Ubuntu-Theos -- bash scripts/test-layout.sh
```

The Settings entry is a navigation-bar item rather than an inserted private Threads settings cell. That makes it substantially less coupled to Threads' internal table or collection-view implementation. It appears for English, Traditional Chinese, and Simplified Chinese Settings titles.

## Sileo repository

Once GitHub Pages is enabled, add this URL in Sileo:

```
https://ice21415.github.io/ThreadsNoSpoiler/
```

The generated APT metadata and the current package are in `docs/`. When releasing a new build, replace the `.deb` in that directory and regenerate `Packages`, `Packages.gz`, and `Release` before pushing.

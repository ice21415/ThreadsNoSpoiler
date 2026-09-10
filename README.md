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

The resulting Debian package belongs on a jailbroken test device. This Windows workspace has no Theos toolchain, so it cannot build the package here.

## Scope

The Settings entry is a navigation-bar item rather than an inserted private Threads settings cell. That makes it substantially less coupled to Threads' internal table or collection-view implementation. It appears for English, Traditional Chinese, and Simplified Chinese Settings titles.

## Sileo repository

Once GitHub Pages is enabled, add this URL in Sileo:

```
https://ice21415.github.io/ThreadsNoSpoiler/
```

The generated APT metadata and the current package are in `docs/`. When releasing a new build, replace the `.deb` in that directory and regenerate `Packages`, `Packages.gz`, and `Release` before pushing.

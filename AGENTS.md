# Working on MacHop

Notes for AI coding agents, and for people. MacHop is a macOS menu-bar app that sends the Mac's keyboard and trackpad to an iPhone over Bluetooth LE. Read [README.md](README.md) for what it does and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how.

## Commands

```sh
scripts/test.sh       # all tests, about 2 seconds; run before every commit
scripts/install.sh    # test, build, install to /Applications and open
scripts/release.sh    # build the signed release zip into dist/
scripts/lab.sh doctor # testing on a real iPhone; see CONTRIBUTING.md
```

Command Line Tools are enough; Xcode isn't needed.

## Ground rules

- **Reliability first.** A simple feature that always works beats a clever one that sometimes doesn't.
- **Test every behaviour change.** Decision logic lives in `MacHopCore` and is tested against the simulated iPhone in `VirtualPhone`. A bug fix should come with a test that fails without it.
- **Only claim it works on a real iPhone if someone saw it,** in the lab or by hand. Passing simulator tests aren't proof.
- **Lab safety:** lab tests act only while Settings is showing on the iPhone (typing only in Notes). Never send typing or clicks to an iPhone screen you haven't checked.
- **Security** (see [SECURITY.md](SECURITY.md)):
  - never log keystrokes or typed text;
  - add no network code and no third-party dependencies;
  - keep the hardened runtime and the automation socket's certificate check;
  - send Bluetooth input only to the chosen iPhone.
- **Releases** are new commits and new version tags. `main` and `v*` tags are protected, so never rewrite history.
- **Writing:** plain, friendly wording in the app and docs. Keep the public docs short.

If a `private/HANDOVER.md` exists (the maintainer's local notes), read it first.

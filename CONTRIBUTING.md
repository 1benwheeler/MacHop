# Contributing to MacHop

Thanks for your interest! Bug reports, ideas and pull requests are all welcome. The top priority is reliability: a feature that works every time beats a clever one that sometimes doesn't.

## Build and run

You need macOS 14 or later and Apple's free Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

```sh
scripts/setup-signing.sh   # once: a local signing identity, so macOS permissions survive rebuilds
scripts/test.sh            # all automated tests, about 2 seconds
scripts/install.sh         # test, build, install to /Applications and open
```

`scripts/build.sh` builds `build/MacHop.app` without installing it. How the code fits together is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Tests

`scripts/test.sh` runs over 100 tests in a few seconds, with no permissions, Bluetooth or iPhone needed. They exercise the real decision code against a simulated iPhone that decodes MacHop's Bluetooth reports with its own parser. That covers:

- crossings, clicks, keys, scrolling and gestures;
- thousands of randomised edge crossings across different display layouts;
- Bluetooth stalls and disconnections;
- the rule that nothing is ever left held down.

Pass any `swift test` arguments through, for example `scripts/test.sh --filter Simulation`.

New behaviour should come with a test. Bug fixes ideally include one that fails without the fix.

## Testing on a real iPhone

Some things only a real iPhone can answer. `machop-lab` drives the iPhone through MacHop and watches its screen over USB to check what actually happened.

1. Turn on MacHop's automation socket, then quit and reopen MacHop:
   `defaults write local.machop AutomationEnabled -bool YES`. Turn it off again with `defaults delete local.machop AutomationEnabled`.
2. Connect the iPhone with a USB cable, unlock it, and tap **Trust** if asked.
3. Open **Settings** on the iPhone. The lab's tests refuse to run on any other screen; the typing test runs only in Notes. That way they can never type into your other apps.
4. Run `scripts/lab.sh doctor`, then for example:
   - `scripts/lab.sh pointer`: pointer placement accuracy.
   - `scripts/lab.sh roundtrips --count 30`: 30 crossings onto the iPhone and back.

   Keep your hands off the Mac during a run. Run `scripts/lab.sh` with no arguments for the full list.

## Making a release

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Run `scripts/release.sh`, which tests, builds a universal app and zips it into `dist/`.
3. Attach the zip to a GitHub release.

Always sign releases with the same identity (`scripts/setup-signing.sh` keeps it in `~/Library/Application Support/MacHop Signing`). macOS ties users' Accessibility and Bluetooth permissions to it, so a different identity would make everyone re-grant them.

## Licence

MacHop is licensed under the AGPL-3.0. By contributing, you agree that your contributions are licensed the same way.

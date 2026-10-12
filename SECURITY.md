# Security

MacHop has Accessibility access on your Mac, which lets it read your keyboard and trackpad so it can pass them to your iPhone. Security issues are taken seriously.

## Reporting a vulnerability

Please report it privately, not in a public issue: go to the repository's **Security** tab and choose **Report a vulnerability**. Include what you found and how to reproduce it. You'll get a reply as soon as possible, and credit in the fix if you'd like it.

Please report issues against the [latest release](https://github.com/1benwheeler/MacHop/releases/latest).

## How MacHop protects you

- **No network access.** MacHop has no internet code and sends nothing anywhere except Bluetooth input to your own iPhone. There's no analytics or tracking.
- **Nothing you type is recorded.** Keystrokes are passed to the iPhone and never logged or stored.
- **Bluetooth goes only to your iPhone,** over an encrypted, paired connection. Input reports are sent only to the iPhone you chose, and other devices can't read or change MacHop's input state.
- **Password fields stay private.** While macOS Secure Input is active (for example, in a password field), MacHop won't send input to the iPhone.
- **Signed with the hardened runtime,** so other programs can't inject code into MacHop to borrow its permissions.
- **The developer automation channel is off by default.** When it's on, it accepts only programs signed with the same certificate as MacHop itself.
- **No third-party code.** MacHop uses only Apple's frameworks.

## Verifying a download

Each release lists the SHA-256 of its zip. Check yours with:

```sh
shasum -a 256 MacHop-<version>.zip
```

Or build it yourself from source (see [CONTRIBUTING.md](CONTRIBUTING.md)).

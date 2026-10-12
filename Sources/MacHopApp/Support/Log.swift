// SPDX-License-Identifier: AGPL-3.0-only
import os

/// Structural diagnostics only: connection and ownership changes, never typed
/// keys, report contents or device names. View with:
///   /usr/bin/log stream --predicate 'subsystem == "local.machop"'  (zsh has its own `log`)
enum Log {
    static let bluetooth = Logger(subsystem: "local.machop", category: "bluetooth")
    static let input = Logger(subsystem: "local.machop", category: "input")
    static let app = Logger(subsystem: "local.machop", category: "app")
    static let automation = Logger(subsystem: "local.machop", category: "automation")
}

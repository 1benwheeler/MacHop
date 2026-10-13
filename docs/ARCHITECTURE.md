# How MacHop works

For every keyboard, pointer, scroll and gesture event on the Mac, MacHop decides whether the Mac or the iPhone should get it. When it's the iPhone, MacHop sends the event over Bluetooth as a keyboard or pointer report, and the iPhone shows it with AssistiveTouch.

```
macOS input ──► EventTap ──► InputSession ──► HIDTransport ──► HIDPeripheral ──► iPhone
                (capture)    (decisions)      (order, pace)    (Bluetooth LE)    (AssistiveTouch)
```

## Code layout

| Module | What's in it |
| --- | --- |
| `MacHopCore` | All the decisions: `InputSession`, the edge geometry (`ScreenLink`), the Bluetooth report formats (`HIDProfile`), the send queue (`HIDTransport`). Pure Swift, no Apple frameworks, so it can be tested without hardware. |
| `MacHopApp` | The macOS side: input capture, the hidden Mac cursor, Bluetooth, and the menu-bar app and window (SwiftUI). |
| `VirtualPhone` | A simulated iPhone that decodes MacHop's reports independently, used by the tests. |
| `LabKit`, `machop-lab` | Tools for testing on a real iPhone (see [CONTRIBUTING.md](../CONTRIBUTING.md)). |

## The rules that keep input safe

- **A release always goes where the press went.** A key or button pressed on one side is released on that side, even if you've crossed in between. Nothing gets stuck down.
- **Gestures belong to where they started.** A scroll or swipe that began on the Mac finishes on the Mac, and momentum never leaks across. While you're on the iPhone, Mac gestures like Mission Control can't fire.
- **Control comes back to the Mac whenever something's wrong.** That covers ⌃⌥⌘⎋, sleep, screen lock, Secure Input (a password field), Bluetooth dropping, or macOS pausing input capture. Anything held on the iPhone is released at once.

## Crossing the edge

- **Resistance:** you push a few points past the edge before crossing, so brushing the edge doesn't switch devices.
- **Forgiving ends:** a push just past either end of the iPhone's part of the edge still crosses, landing at the iPhone's nearest corner.
- **Sliding isn't pushing:** mostly up-and-down movement along an edge never crosses, so a slight sideways drift can't bounce you between devices.
- **Momentum:** movement past the resistance carries over, so a fast flick keeps going on the other side.
- **The menu bar:** at the top edge, movement that arrives at the edge doesn't count, and it always takes at least a medium push, so flinging the pointer at the menu bar stays on the Mac.

The iPhone's pointer is driven to absolute positions on a virtual iPhone placed beside or above your display, so returning to the Mac lands at the matching place, unaffected by iOS's pointer acceleration.

## The hidden Mac cursor

While you're on the iPhone, the Mac's cursor is hidden, and whenever it nears a screen edge it's moved back to the middle, so it can't trigger the Dock or a hot corner. macOS adds that jump to the next movement it reports, so MacHop subtracts it again. The move is a posted mouse event rather than a "warp", because a warp makes macOS ignore the mouse for a quarter of a second. Hiding the cursor from a background app uses a private WindowServer setting, the same one other keyboard-and-mouse sharing tools use; if it's ever unavailable, the cursor simply stays visible.

## Bluetooth

MacHop publishes a standard Bluetooth LE keyboard and pointer (HID over GATT), and keeps a connection open to your chosen iPhone, so it reconnects by itself whenever the iPhone comes back into range. Reports are sent strictly in order and paced to the Bluetooth connection interval. Pointer moves can be combined when the radio is busy, but clicks and keys never are. If the radio stops responding, input returns to the Mac and everything is released.

The iPhone reports its model over the same connection, which is how MacHop knows its screen shape.

## What iPhone allows

iPhone supports a Bluetooth pointer only through AssistiveTouch. That shapes three features:

- **Scrolling:** wheel scrolling is unreliable on iPhone, and touch surfaces are ignored, so two-finger scrolling is sent as a press-and-drag, the way AssistiveTouch drags with a finger.
- **Gestures:** three-finger swipes press extra mouse buttons (4, 5 and 6), which you assign to Home, the App Switcher and Notification Centre once in AssistiveTouch.
- **The pointer itself:** iOS draws and fades it; a Bluetooth pointer can't hide it.

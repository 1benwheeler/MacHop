# Roadmap

## Next

- **iPhone below the screen.** Today the iPhone sits to the left, right or top of a display. Below suits desktop Macs, where the phone often lies on the desk in front of the monitor. It needs care around the Dock, which already uses that edge.
- **iMac drawing.** An iMac's built-in screen is currently drawn as a MacBook.

## Ideas

- **Three-finger left/right to switch apps.** iPhone has no AssistiveTouch action for this, so it would need a faked drag along the bottom edge. It's only worth doing if it can be made reliable.

## Not possible on iPhone today

- **Scrolling with the pointer standing still:** iPhone handles wheel scrolling from a Bluetooth mouse unreliably and ignores touch surfaces, so MacHop scrolls by dragging.
- **Pinch to zoom:** iPhone ignores touch input from Bluetooth devices.
- **Hiding the pointer instantly:** iOS fades the AssistiveTouch pointer about 15 seconds after it stops moving, and a Bluetooth pointer can't hide it sooner.
- **App Switcher and Notification Centre without setup:** no keyboard key opens them on iPhone, so those swipes use AssistiveTouch's assignable buttons. (Home uses the keyboard's Menu key, so it needs none.)

Found a bug or have an idea? [Open an issue](https://github.com/1benwheeler/MacHop/issues).

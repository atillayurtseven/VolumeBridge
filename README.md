# VolumeBridge

A menu bar app that makes the Mac's volume keys work on outputs with no volume control, such as DisplayPort and HDMI monitors. It captures system audio with a Core Audio Process Tap, applies gain, and plays it back on the same output. It needs no audio driver and no DDC.

If the app quits or crashes, audio returns to normal by itself. On outputs with native volume control, such as the built-in speakers, the app stays out of the way.

## Requirements

- macOS 14.4 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build and install

```bash
git clone https://github.com/atillayurtseven/VolumeBridge.git
```

```bash
cd VolumeBridge && ./build.sh install
```

This installs and launches `/Applications/VolumeBridge.app`. The first build creates a local self-signed certificate named `VolumeBridge Dev`, which keeps macOS permissions valid across rebuilds. If Keychain asks for your password, choose **Always Allow**.

## Permissions

Grant these once on each Mac:

- **Accessibility**, to capture the volume keys: System Settings → Privacy & Security → Accessibility.
- **System audio recording**, to process the audio. Allow it when prompted, or there will be no sound.

## Keys

| Keys | Action |
|---|---|
| Volume up / down | Change volume in 16 steps; hold to repeat |
| Mute | Toggle mute |
| ⌥⇧ + volume up / down | Change volume in quarter steps |
| ⌥ + volume key | Open Sound settings |

## Known issue

While Dell Display and Peripheral Manager (DDPM) is running, volume key presses can get lost and holding a key may not repeat. If that happens, quit DDPM and remove it from your login items.

## License

[MIT](LICENSE)

# mousemap

A small macOS background tool for a regular mouse:

- **Smooth, trackpad-style scrolling** for the mouse wheel: the page follows
  the wheel one to one and, after a fast spin, coasts to a stop along the same
  curve as macOS's trackpad momentum. Apps that scroll by lines (like
  Terminal) are told about lines the way a trackpad reports them, so one speed
  feels right everywhere. In iPhone Mirroring, which animates every scroll
  event on the phone, the same movement goes out in fewer, bigger steps (15 a
  second) so the phone follows the wheel instead of jumping when it stops.
- **Reverse the mouse wheel only.** macOS has one "natural scrolling" switch
  for mouse and trackpad together; keep it on for the trackpad and flip just
  the wheel.
- **Remap the side buttons** (back / forward) and the wheel click to keyboard
  shortcuts, media keys or shell commands.
- **Per-app settings**, e.g. a different scroll speed or button action in one app.

One Swift file, no dependencies. Nothing is written to the mouse; it all
happens on the Mac through an event tap. Trackpads and Magic Mouse are left
alone.

## Install

Needs macOS 12 or later (tested on macOS 27) and the Swift compiler
(`xcode-select --install`).

    git clone https://github.com/Anubhav-Rai/mousemap.git
    cd mousemap
    ./install.sh

This builds it, installs it to `~/.local/bin/mousemap` (put that on your
`PATH`), and starts it now and at every login. Then allow **mousemap** in
System Settings > Privacy & Security > Device Control and Data Access (called
"Accessibility" on older macOS). It starts working within a couple of seconds.

install.sh signs the binary with a self-signed certificate it creates on first
run (kept in `.signing/`, never committed), so the permission survives
rebuilds. Delete `.signing/` and you'll have to allow it again.

To remove: `./uninstall.sh` (keeps your config in `~/.config/mousemap`).

## Use

    mousemap show                               # current settings
    mousemap set scroll_speed 1.2               # change a setting everywhere
    mousemap set Preview scroll_speed 0.5       # ...or for one app
    mousemap unset Preview scroll_speed         # back to the everywhere value
    mousemap set forward ctrl+up                # Forward button opens Mission Control
    mousemap status                             # running? config valid? recent log
    mousemap apps                               # app names and bundle IDs
    mousemap off / on                           # stop / start
    mousemap edit                               # open the config file

Changes apply immediately. Settings live in `~/.config/mousemap/config.json`,
which also documents every option.

## Settings

| Setting | Default | |
|---|---|---|
| `smooth_scroll` | `true` | smooth scrolling for the mouse wheel |
| `scroll_speed` | `1.0` | how far each notch scrolls; 2.0 = twice as far |
| `scroll_smoothness` | `1.0` | glide of each notch; 0.5 = snappier, 2.0 = floatier |
| `scroll_momentum` | `1.0` | coasting after fast scrolling; 0 = none, 2.0 = longer |
| `scroll_reverse` | `false` | flip the mouse wheel only |
| `back`, `forward`, `middle` | normal | button actions, see below |

Button actions: a shortcut like `cmd+c`, `ctrl+left`, `cmd+shift+]`, `f11`;
a media key like `media:volume_up`, `media:play_pause`; a command like
`shell:open -a Safari`; `none` to disable the button; `default` for its
normal behaviour.

Per-app settings (buttons and `scroll_*`) apply while that app is in front.

Log: `~/Library/Logs/mousemap.log`

## License

MIT, see [LICENSE](LICENSE).

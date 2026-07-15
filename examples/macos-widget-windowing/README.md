# macOS widget windowing harness

This physical-test harness launches the full AppKit policy matrix in one
widget-only process:

| layer | interactive | pointer pass-through |
| --- | --- | --- |
| bottom | `bottom-input` | `bottom-pass` |
| normal | `normal-input` | `normal-pass` |
| topmost | `topmost-input` | `topmost-pass` |

Every window is chromeless, transparent, nonactivating, and rendered through a
premultiplied Metal `gpu_surface`. Build and run it from this directory:

```sh
../../zig-out/bin/native build -Dplatform=macos -Dweb-engine=system
NATIVE_SDK_WINDOW_POLICY=1 zig-out/bin/macos-widget-windowing
```

The opt-in policy log prints each window id beside its resolved Core Graphics
level, input mode, activation policy, and collection behavior. Use it to
correlate a screen recording with `app.zon` rather than identifying windows by
position alone.

# macOS renderer resource probe

This PR-06-only probe measures two startup shapes with the same presenter and
compositor shaders as the AppKit host:

- runtime source compilation once per view;
- one precompiled metallib, command queue, pipeline set, and sampler cached for
  the process, plus a bounded three-buffer upload ring per surface.

It is not a renderer and does not change a production default. Build and run it
on macOS with the public Metal toolchain:

```sh
mkdir -p .zig-cache/macos-renderer-probe
xcrun -sdk macosx metal -c tools/macos-renderer-bakeoff/shaders.metal -o .zig-cache/macos-renderer-probe/shaders.air
xcrun -sdk macosx metallib .zig-cache/macos-renderer-probe/shaders.air -o .zig-cache/macos-renderer-probe/shaders.metallib
xcrun swiftc tools/macos-renderer-bakeoff/probe.swift -framework Foundation -framework Metal -o .zig-cache/macos-renderer-probe/renderer-probe
.zig-cache/macos-renderer-probe/renderer-probe tools/macos-renderer-bakeoff/shaders.metal .zig-cache/macos-renderer-probe/shaders.metallib 10
```

The probe reports object counts and declared resource bytes rather than
pretending those equal physical footprint. Whole-process footprint belongs to
Weaver's production-runtime harness.

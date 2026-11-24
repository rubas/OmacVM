# Where a key's time goes on the way to the screen (OmacVM.app, 120 Hz)

A key on a Chromium page that redraws at 120 frames a second reached QEMU's layer 43 to 58 ms after QEMU
got it (median 55 over 16 runs), against 7 to 17 ms in a terminal or on a still page. Frame queues in
Chromium, Hyprland and QEMU hold most of it. Chromium's own queue is the cheapest to cut:
`--double-buffer-compositing` takes about 10 ms off (branch `chromium-double-buffer`).

## How it was measured

Mac mini M4 Pro, 2026-11-24. A test VM (6 vCPUs, 8 GB, Omarchy with Hyprland 0.57.2, Chromium 157, foot)
ran full screen at 5120x2880 on a 120 Hz virtual display; the guest's mode is 120.061 Hz. QEMU was today's
present with the frame check of the scanout prototype on (`OMACVM_TEST_PACE_CHECK=1`, which needs
`OMACVM_GL_LOSSLESS=0`): as each frame goes on the window's layer, QEMU reads a marker cell from it and logs
when the marker flips. That commit is 3 ms before the vsync, so add about 3 ms for the screen; the session
has no Screen Recording permission, so the screen itself was not read.

Each run sent 60 keys through QMP, 220 to 320 ms apart, under the bench lock. A page or a terminal flips the
marker on each key: `pace2.html` (a 5K canvas, redrawn every frame or only on a key) or a full-screen foot
running a small program that repaints a block per key. Keys posted as Mac events into QEMU
(`CGEventPostToPid`) took 0.5 to 0.7 ms (median, p90 2.3 ms) to reach QEMU's input layer and gave the same
totals.

The stages come from three clocks. QEMU's log has the key, each `RESOURCE_FLUSH` and the frame on the layer.
The guest's ftrace (`CLOCK_MONOTONIC`) has the virtio-input interrupt, Hyprland's key to the client, surface
commits, render start, the fence wait of its atomic commit, the flush and the vblank (uprobes on Hyprland,
kprobes on the kernel). Chromium's trace (`LINUX_CLOCK_MONOTONIC`) has the key handler and each frame's
pipeline stages. The guest and host clocks were tied together from both directions, the key into the guest
and the flush out of it, to within 0.03 to 0.11 ms. Chromium's presentation time of the marked frame equals
the guest vblank after the flush the chain picked, for every key. Tracing moved the total by less than the
run-to-run spread (52 to 57 ms traced, 54 to 58 untraced).

## The stages

Medians in ms; the two Chromium page columns are the means of two runs each.

| Stage | Chromium, page at 120 fps | the same with `--double-buffer-compositing` | Chromium, still page | foot, still desktop | foot, output at 125 Hz |
|---|---|---|---|---|---|
| QEMU's key to the guest's interrupt | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 |
| to Hyprland sending the key | 0.3 | 0.4 | 0.4 | 0.7 | 1.0 |
| to Chromium's handler done | 0.7 | 0.9 | 0.9 | | |
| to the next main frame (rAF) | 2.7 | 2.7 | 0.4 | | |
| main frame, commit, frame submitted | 9.1 | 9.7 | 1.1 | | |
| Viz waits for its draw | 6.9 | 6.9 | 0.4 | | |
| Viz draws | 0.6 | 0.8 | 0.4 | | |
| swap: until Chromium commits the buffer to Hyprland | 15.4 | 6.9 | 3.0 | | |
| foot: key to its commit | | | | 1.3 | 1.4 |
| commit to Hyprland's next render | 8.1 | 7.2 | 0.2 | 0.2 | 2.6 |
| render to its GPU work done on the Mac | 3.0 | 3.1 | 2.7 | 3.0 | 3.1 |
| flush to QEMU | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 |
| QEMU's present of the frame | 1.4 | 1.4 | 1.3 | 1.3 | 1.3 |
| queue to the refresh that shows it | 7.4 | 5.3 | 0.3 | 0.3 | 4.9 |
| total to the layer | 55.8 | 45.7 | 10.8 | 7.1 | 16.8 |

Without tracing, in one VM start: Chromium idle 10 to 17 ms, idle while the pointer moves (Hyprland draws
every refresh) 20 to 23 ms, foot on a still desktop 7 to 8 ms, foot while it prints or the pointer moves 15
to 17 ms. For foot at 125 Hz the first commit after the key does not always carry it, so its stages add up
to 14.4 of the 16.8 ms.

## Why the queues hold frames

- Chromium commits a finished buffer only after Hyprland's frame callback for the one before
  (`ui/ozone/platform/wayland/host/wayland_frame_manager.cc:181`), and Viz lets up to two swaps wait
  for that: three buffers, `max_pending_swaps` = 2
  (`components/viz/service/display_embedder/skia_output_device_buffer_queue.cc:174,189-192`). On a page that
  draws every refresh both slots stay full, so a frame waits about two refreshes (15.4 ms).
  `--double-buffer-compositing` makes it two buffers and one waiting swap (6.9 ms).
- Hyprland renders as soon as the guest's vblank comes (`src/output/MonitorFrameScheduler.cpp:106` in
  0.57.2) and sends the frame callbacks from inside that render, after it built the frame
  (`src/render/Renderer.cpp:2453`; 0.56.2 has the same order). Chromium's waiting buffer arrives 0.2 to
  0.3 ms later and waits for the next vblank (7 to 8 ms). A client that draws only after the key, like foot or
  a still page, is not behind a callback and lands in the next render (0.2 ms).
- QEMU's jitter buffer (ADR 0020) shows a frame at the first commit 3 ms before a vsync. The guest's
  120.061 Hz runs ahead of the display, so a second frame builds up; the quarter-second trim
  (`qemu-cocoa-gl-present-trim.patch`) needs a frame left over after 30 refreshes in a row, and one
  refresh without one starts the count again. Over 327 s of 120 fps frames in 17 runs, the wait from the
  present to its refresh averaged 7.9 ms (p10 5.3, p90 10.3) instead of about 4.2 for a free phase,
  and a third of the frames came while one was already queued.

## The A/B of `--double-buffer-compositing`

In one VM start, A B B A, twice, with the switch on Chromium's command line: without it 57.0, 52.2, 57.0
and 48.6 ms, with it 41.2, 44.6, 43.5 and 44.2 ms (medians of 60 keys). The page drew 118.2 to 119.9 frames
a second either way; frames skipped on the layer were 3, 12, 10 and 5 without and 0, 1, 0 and 0 with it.
Through Arch's launcher reading `/etc/chromium-flags.conf` (the branch's `src/app/guest/install.sh`, the
switch in Chromium's command line in the trace): 55.6 and 56.0 ms without, 46.5 and 44.8 with it; a still
page 10.8 and 10.9. QEMU's queue wait moves with the guest's phase and was not lower with the switch (6.4
to 9.3 ms a run without, 6.1 to 9.3 with it); the gain is Chromium's swap.

The cost is frames when Chromium's GPU work fills the refresh: a canvas with 40 full-screen translucent
fills a frame ran at 96 to 98 frames a second with the switch and 99 to 118 without (four runs each). H.264
clips at 1080p60 and 2160p60 dropped 0 to 2 of 1320 frames either way. Chromium's
`WaylandExternalBeginFrameSource` (begin frames paced by `wp_presentation`) gave nothing: 58.7 and 53.2 ms
against 52.3 and 54.6.

## What is left

- Hyprland: send the frame callbacks, then render a millisecond or two later, as sway's `max_render_time`
  does. Chromium's buffer would land in the same render: about 7 ms for Chromium and Electron apps. It
  needs a Hyprland patch (or a plugin) for each release.
- QEMU: trim the standing second frame sooner, about 3 to 4 ms on average at 120 fps. Each skip shows as a
  skipped frame, and the jitter buffer exists to absorb arrival jitter at that phase, so it trades pacing
  for latency. The vblank lock (ADR 0056, removed in 0057) moved the guest's phase instead and gave 0 to
  2.6 ms at 120 Hz.
- Chromium's own begin-frame and draw deadlines (about 19 ms on an animating page) are Chromium's design.

# Promo video

`promo-<lang>.gif` is the README hero; `promo-<lang>.mp4` is the full-quality version it links to.
Both are rendered from the app's own views with made-up demo data (`src/DemoData.swift`,
`src/PromoRenderer.swift`), so nothing real appears in them.

```sh
swiftc -O src/*.swift -o bin/herdr-island
./bin/herdr-island --promo /tmp/promo-en en            # 450 PNG frames, 15 s at 30 fps
ffmpeg -framerate 30 -i /tmp/promo-en/frames/frame_%04d.png \
  -vf "scale=1280:-2:flags=lanczos,format=yuv420p" -c:v libx264 -crf 20 -preset slow \
  -movflags +faststart docs/media/promo-en.mp4
ffmpeg -framerate 30 -i /tmp/promo-en/frames/frame_%04d.png \
  -vf "fps=20,scale=1100:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  docs/media/promo-en.gif
```

Pass a comma-separated list of times as a third argument to render just those stills
(`--promo /tmp/check en 1.5,3.4,6.2`) when adjusting the script.

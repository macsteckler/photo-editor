# Nitrate

A film-look processor for iPhone photos that runs in the browser. Everything happens on the phone in WebGL; no photos are uploaded.

## Pipeline

1. Undo phone over-sharpening with a slight blur, scaled to the image size.
2. Set white balance and exposure in scene-linear light, then add lens falloff (vignette).
3. Add halation (red-orange scatter around highlights) and bloom from a multi-scale glow pyramid. The pyramid is built from the preview image, so the preview and the export match.
4. Apply dye-density saturation in log space, so dark colors get denser instead of neon.
5. Apply a per-channel film characteristic curve with a soft toe, a long shoulder and a lifted print black.
6. Grade in Oklab: shift greens toward olive and blues toward teal, set warm and skin tones, split-tone (cool shadows, warm highlights), and compress chroma the way print dyes do.
7. Add grain that depends on luminance. Its size is relative to the frame.
8. Optionally add a film-gate frame with rounded, slightly irregular edges.

## Looks

| Look | Character |
|------|-----------|
| Monsoon | Cool teal shadows, hot reds, heavy grain and halation, gate frame |
| Lantern | Warm tungsten interiors, teal-olive greens, deep blues |
| Golden | Golden-hour sun, olive greens, warm highlights |
| Print | Neutral cinematic print |
| Overcast | Muted, low contrast, lifted blacks |
| Silver | Black and white |

Every look can be adjusted with the Color and Texture sliders. Double-tap a slider's label to reset it.

## Use it on iPhone

1. Host the folder over HTTPS. This repo deploys to GitHub Pages from `main`; to set that up, go to Settings → Pages → Source and choose **GitHub Actions**.
2. Open the page in Safari, then tap Share → **Add to Home Screen**. The app then works offline.
3. Tap **Open**, pick one or more photos, choose a look, then tap **Export** → **Save to Photos**.

Exports are full-resolution JPEGs, capped at about 25 MP. EXIF metadata (date, location) is not carried over.

## Run locally

```
python3 -m http.server 8000
```

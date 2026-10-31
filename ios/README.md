# Nitrate for iPhone (native camera)

A camera app that captures **RAW sensor data** and develops it with the Nitrate film pipeline, the same one as the web app, ported to Metal.

- **RAW mode** (the default) captures a single Bayer frame from the sensor. Apple's processing never touches it: no Smart HDR, Deep Fusion, local tone mapping or sharpening.
- **ProRAW mode** (Pro models) captures Apple's multi-frame computational RAW, up to 48 MP, developed down to 24 MP. Nitrate still turns off Apple's tone curve boost, local tone mapping, sharpening, and contrast and detail enhancement.
- **Developing:** Core Image's RAW decoder handles demosaicing and the camera color matrices, and outputs scene-linear light with highlight headroom. Nitrate's film pipeline then renders the tone and color.
- **Viewfinder:** shows the selected look live. Press and hold the viewfinder to see the image without the look.
- **Saving:** each capture is saved to Photos as a developed JPEG. With "keep RAW" on (the document icon), the original DNG is attached, so Photos stores it as a RAW+JPEG pair.
- **Library:** tap the thumbnail to open a ProRAW/DNG (or any photo) from your library, change the look, and save.

## Build and install

You need a Mac with Xcode 15 or later. Swift Playgrounds 4.4+ on a Mac or iPad also works.

1. Open `ios/Nitrate.swiftpm` in Xcode.
2. Select the **Nitrate** scheme and your iPhone as the run destination. Connect the phone by cable the first time and enable Developer Mode on it (Settings → Privacy & Security).
3. Under Signing & Capabilities, pick your team. A free Apple ID works, but the app expires after 7 days and must be re-run from Xcode. A paid developer account lasts a year. If Xcode reports the bundle ID is taken, change `bundleIdentifier` in `Package.swift`, e.g. `com.yourname.nitrate`.
4. Press Run.

Requirements: iOS 17 or later. ProRAW mode appears only on iPhone 12 Pro and later Pro models.

// swift-tools-version: 5.9

// Open this folder in Xcode (File > Open… > Nitrate.swiftpm) or Swift Playgrounds on a Mac/iPad.
// Set your team in Signing & Capabilities, pick your iPhone, and Run.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Nitrate",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Nitrate",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.nitrate",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .camera),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait
            ],
            capabilities: [
                .camera(purposeString: "Nitrate captures RAW photos from the camera."),
                .photoLibraryAdd(purposeString: "Nitrate saves developed photos (and their RAW files) to your library.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)

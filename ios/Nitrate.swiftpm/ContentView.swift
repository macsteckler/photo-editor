import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

@main
struct NitrateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

/// A photo to open in the editor (a capture, or a file from the library).
struct EditorItem: Identifiable {
    let id = UUID()
    let data: Data
    let attachRawOnSave: Bool
}

/// Loads RAW originals from the photo library when they exist, otherwise the image.
struct ImageFile: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .rawImage) { ImageFile(data: $0) }
        DataRepresentation(importedContentType: .image) { ImageFile(data: $0) }
    }
}

struct ContentView: View {
    @StateObject private var settings = FilmSettings()
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("keepRaw") private var keepRaw = true

    @State private var showAdjust = false
    @State private var developing = 0
    @State private var message: String?
    @State private var lastThumb: UIImage?
    @State private var lastCapture: Data?
    @State private var editing: EditorItem?
    @State private var pickerItem: PhotosPickerItem?
    @State private var bypass = false

    var body: some View {
        VStack(spacing: 12) {
            topBar
            viewfinder
            LookPicker(settings: settings)
            bottomBar
        }
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            camera.onCapture = { data in handleCapture(data) }
            camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        .onChange(of: camera.lastError) { _, err in if let err { flash(err) } }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let file = try? await item.loadTransferable(type: ImageFile.self) {
                    editing = EditorItem(data: file.data, attachRawOnSave: false)
                } else {
                    flash("Couldn't load that photo.")
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $showAdjust) {
            AdjustSheet(settings: settings)
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        }
        .fullScreenCover(item: $editing) { item in
            EditorView(item: item, settings: settings)
        }
    }

    private var topBar: some View {
        HStack {
            Text("NITRATE").font(.system(size: 13, weight: .semibold)).kerning(4)
            Spacer()
            if camera.proRAWSupported {
                Picker("Mode", selection: $camera.rawMode) {
                    ForEach(CameraModel.RawMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            Button {
                keepRaw.toggle()
                flash(keepRaw ? "RAW file kept with each photo" : "Saving developed JPEG only")
            } label: {
                Image(systemName: keepRaw ? "doc.badge.plus" : "doc")
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                if camera.authorized {
                    FilmMetalView(settings: settings, source: .camera(camera), bypass: bypass)
                        .onTapGesture(coordinateSpace: .local) { p in
                            camera.focus(at: CGPoint(x: p.x / geo.size.width, y: p.y / geo.size.height))
                        }
                        .onLongPressGesture(minimumDuration: 0.25, perform: {}, onPressingChanged: { bypass = $0 })
                } else {
                    Text("Allow camera access in Settings → Nitrate.").foregroundStyle(.secondary)
                }
                if camera.shutterFlash { Color.black }
                VStack {
                    if bypass { badge("Original") }
                    Spacer()
                    if let message { badge(message) }
                }
                .padding(10)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                Group {
                    if let lastThumb {
                        Image(uiImage: lastThumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").font(.title2)
                    }
                }
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .contextMenu {
                if let lastCapture {
                    Button("Re-develop last capture") { editing = EditorItem(data: lastCapture, attachRawOnSave: false) }
                }
            }
            Spacer()
            Button { camera.capture() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(developing > 0 ? Color.orange : Color.white).frame(width: 60, height: 60)
                }
            }
            Spacer()
            Button { showAdjust = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title2)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.6)).clipShape(Capsule()).foregroundStyle(.white)
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if message == text { message = nil } }
    }

    /// Develop a capture with the settings at the moment of capture and save it.
    private func handleCapture(_ data: Data) {
        DispatchQueue.main.async {
            let snap = settings.snapshot()
            let attach = keepRaw
            developing += 1
            Task.detached(priority: .userInitiated) {
                do {
                    let developed = try RawDeveloper.develop(data: data)
                    guard let cg = FilmRenderer.shared.renderImage(linear: developed.texture, settings: snap, seed: Float.random(in: 1...10)),
                          let jpeg = RawDeveloper.jpegData(cg, properties: developed.properties) else {
                        throw RawDeveloper.DevelopError.unreadable
                    }
                    try await PhotoSaver.save(jpeg: jpeg, raw: attach ? data : nil)
                    let thumb = UIImage(cgImage: cg).preparingThumbnail(of: CGSize(width: 156, height: 208))
                    await MainActor.run {
                        developing -= 1
                        lastThumb = thumb
                        lastCapture = data
                        flash("Saved")
                    }
                } catch {
                    await MainActor.run {
                        developing -= 1
                        flash(error.localizedDescription)
                    }
                }
            }
        }
    }
}

/// Develops one photo and lets you change the look before saving.
struct EditorView: View {
    let item: EditorItem
    @ObservedObject var settings: FilmSettings
    @Environment(\.dismiss) private var dismiss
    @State private var developed: RawDeveloper.Developed?
    @State private var error: String?
    @State private var saving = false
    @State private var showAdjust = false
    @State private var bypass = false
    @State private var message: String?
    @State private var seed = Float.random(in: 1...10)

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Text(developed?.description ?? "Developing…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(saving ? "Saving…" : "Save") { save() }
                    .bold()
                    .disabled(developed == nil || saving)
            }
            .padding(.horizontal, 16)

            ZStack {
                if let developed {
                    FilmMetalView(settings: settings, source: .still(developed.texture), bypass: bypass, seed: seed)
                        .aspectRatio(CGFloat(developed.texture.width) / CGFloat(developed.texture.height), contentMode: .fit)
                        .onLongPressGesture(minimumDuration: 0.25, perform: {}, onPressingChanged: { bypass = $0 })
                } else if let error {
                    Text(error).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView()
                }
                VStack {
                    if bypass { Text("Original").font(.caption).padding(6).background(.black.opacity(0.6)).clipShape(Capsule()) }
                    Spacer()
                    if let message { Text(message).font(.caption).padding(6).background(.black.opacity(0.6)).clipShape(Capsule()) }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LookPicker(settings: settings)
            Button { showAdjust = true } label: {
                Label("Adjust", systemImage: "slider.horizontal.3")
            }
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .task {
            let data = item.data
            do {
                let d = try await Task.detached(priority: .userInitiated) { try RawDeveloper.develop(data: data) }.value
                developed = d
            } catch {
                self.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showAdjust) {
            AdjustSheet(settings: settings)
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        }
    }

    private func save() {
        guard let developed else { return }
        saving = true
        let snap = settings.snapshot()
        let seed = self.seed
        let raw = item.attachRawOnSave && developed.isRaw ? item.data : nil
        Task.detached(priority: .userInitiated) {
            var result = "Saved"
            if let cg = FilmRenderer.shared.renderImage(linear: developed.texture, settings: snap, seed: seed),
               let jpeg = RawDeveloper.jpegData(cg, properties: developed.properties) {
                do { try await PhotoSaver.save(jpeg: jpeg, raw: raw) } catch { result = error.localizedDescription }
            } else {
                result = "Could not render the photo."
            }
            await MainActor.run {
                saving = false
                message = result
            }
        }
    }
}

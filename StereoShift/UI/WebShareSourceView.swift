import PhotosUI
import SwiftUI

extension PhotoWebSourceLabel {
    var title: LocalizedStringKey {
        switch self {
        case .selection: return "Sharing selected iPhone photos and videos"
        case .limited: return "Sharing your limited Photos library"
        case .library: return "Sharing your Photos library"
        }
    }
}

struct WebShareSourceView: View {
    let webServer: GalleryWebServer
    @ObservedObject var access: SubscriptionManager
    let depthEstimator: DepthEstimator
    let strength: Float
    let options: Stereo3DOptions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var usePhotos = false
    @State private var browseLibrary = false
    @State private var results: [PHPickerResult] = []
    @State private var picking = false
    @State private var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var requesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Share from") {
                    Picker("Share from", selection: $usePhotos) {
                        Text("StereoShift Gallery").tag(false)
                        Text("iPhone Photos").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if usePhotos {
                    Section {
                        Picker("Photos to share", selection: $browseLibrary) {
                            Text("Choose Photos & Videos").tag(false)
                            Text("Browse My Library on Quest").tag(true)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        if browseLibrary {
                            libraryPermission
                        } else {
                            Button("Choose Photos & Videos") { picking = true }
                            if !results.isEmpty { Text("Selected items: \(results.count)") }
                        }
                    } header: {
                        Text("Photos to share")
                    } footer: {
                        if browseLibrary {
                            if permission == .limited {
                                Text("Anyone with the link and PIN can browse the photos and videos you allow in iOS for this session.")
                            } else {
                                Text("With full access, anyone with the link and PIN can browse your photos and videos during this session. Hidden items are excluded.")
                            }
                        } else {
                            Text("Anyone with the link and PIN can view only the items you choose for this session.")
                        }
                    }
                    Section {
                        Text(access.canAccessVideo
                             ? "Open a photo or video on Quest to convert it to 3D on your iPhone."
                             : "Open a photo on Quest to view it in 3D. Live 3D video requires paid access.")
                    }
                } else {
                    Section { Text("Anyone with the link and PIN can view the converted items in your StereoShift gallery.") }
                }
                Button("Start Network Share", action: start)
                    .disabled(usePhotos && (browseLibrary ? !PhotoWebShare.permitsBrowsing(permission) : results.isEmpty))
            }
            .navigationTitle("Web Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $picking) {
                WebSharePhotosPicker { picked in
                    if !picked.isEmpty { results = picked }
                    picking = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permission = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
        }
    }

    @ViewBuilder
    private var libraryPermission: some View {
        switch permission {
        case .notDetermined:
            Button("Allow Library Access") {
                requesting = true
                Task { @MainActor in
                    permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    requesting = false
                }
            }.disabled(requesting)
        case .limited: Text("Limited access").font(.headline)
        case .authorized: Text("Full library access").font(.headline)
        default: Text("Library access is unavailable. You can still choose individual items.")
        }
        if permission == .limited || permission == .denied {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }

    private func start() {
        if usePhotos {
            let source: PhotoWebShare.Source = browseLibrary ? .library(permission) : .selected(results.map(\.itemProvider))
            let share = PhotoWebShare(source: source, depthEstimator: depthEstimator, strength: strength, options: options)
            guard webServer.startPhotos(share, access: access) else {
                permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                return
            }
        } else { webServer.start() }
        dismiss()
    }
}

private struct WebSharePhotosPicker: UIViewControllerRepresentable {
    let completion: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([PHPickerResult]) -> Void
        init(completion: @escaping ([PHPickerResult]) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { completion(results) }
    }
}

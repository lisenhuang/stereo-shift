import SwiftUI

struct HomeView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case photo = "Photo"
        case video = "Video"

        var id: String { rawValue }
    }

    @StateObject private var pipeline = StereoPipeline()
    @State private var mode: Mode = .photo
    @State private var strength: Float = 0.9
    @State private var sbsLayoutEnabled = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    modePicker
                    controlsCard

                    if mode == .photo {
                        PhotoFlowView(
                            pipeline: pipeline,
                            strength: $strength,
                            sbsLayoutEnabled: $sbsLayoutEnabled
                        )
                    } else {
                        VideoFlowView(
                            pipeline: pipeline,
                            strength: $strength,
                            sbsLayoutEnabled: $sbsLayoutEnabled
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle("StereoShift")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2D to 3D Side-by-Side")
                .font(.title2.bold())
            Text("Create left-right stereo photos and videos offline with Depth Anything v2.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var controlsCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("3D Strength")
                    .font(.headline)
                Spacer()
                Text(strengthLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(strength) },
                    set: { strength = Float($0) }
                ),
                in: 0.1...1.5
            )

            Toggle("Side-by-Side (SBS)", isOn: $sbsLayoutEnabled)
                .disabled(true)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var strengthLabel: String {
        if strength < 0.45 {
            return "Subtle"
        }
        if strength < 1.0 {
            return "Balanced"
        }
        return "Strong"
    }
}

#Preview {
    HomeView()
}

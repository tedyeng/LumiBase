import SwiftUI

/// Lightroom-style Photo Merge: Panorama -> DNG configuration dialog
public struct PanoramaMergeDialogView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var outputFilename: String = ""
    @State private var autoCrop: Bool = true
    @State private var useHomography: Bool = true
    @State private var maxFrameLongEdge: CGFloat = 3600

    public init(appState: AppState) {
        self.appState = appState
    }

    private var sortedSelected: [PhotoAsset] {
        appState.selectedAssets.sorted { a, b in
            if let da = a.cameraMetadata.captureDate, let db = b.cameraMetadata.captureDate, da != db {
                return da < db
            }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "pano.fill")
                    .uiFont(14, weight: .semibold)
                    .foregroundColor(LightroomTheme.accentYellow)
                Text("Photo Merge: Panorama (DNG)")
                    .uiFont(14, weight: .semibold)
                    .foregroundColor(LightroomTheme.textPrimary)
                Spacer()
                Text("\(sortedSelected.count) photos")
                    .uiFont(11, weight: .medium)
                    .foregroundColor(LightroomTheme.textMuted)
            }
            .padding()
            .background(LightroomTheme.cardBackground)

            Divider().background(LightroomTheme.dividerColor)

            VStack(alignment: .leading, spacing: 14) {
                // Selected files summary
                if let first = sortedSelected.first, let last = sortedSelected.last {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source Photos")
                            .uiFont(11, weight: .semibold)
                            .foregroundColor(LightroomTheme.textSecondary)
                        Text("\(first.filename) … \(last.filename)")
                            .uiFont(11, design: .monospaced)
                            .foregroundColor(LightroomTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                // Output Filename
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output DNG Filename")
                        .uiFont(11, weight: .semibold)
                        .foregroundColor(LightroomTheme.textSecondary)
                    TextField("Panorama.dng", text: $outputFilename)
                        .textFieldStyle(.roundedBorder)
                        .uiFont(11, design: .monospaced)
                }

                // Options
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto Crop (Remove Edge Gaps)", isOn: $autoCrop)
                        .uiFont(11)
                        .foregroundColor(LightroomTheme.textPrimary)

                    Toggle("Perspective Alignment (Homography)", isOn: $useHomography)
                        .uiFont(11)
                        .foregroundColor(LightroomTheme.textPrimary)
                }

                // Frame Resolution
                HStack {
                    Text("Frame Decode Resolution")
                        .uiFont(11, weight: .semibold)
                        .foregroundColor(LightroomTheme.textSecondary)
                    Spacer()
                    Picker("", selection: $maxFrameLongEdge) {
                        Text("Standard (2400 px)").tag(CGFloat(2400))
                        Text("High (3600 px)").tag(CGFloat(3600))
                        Text("Full (5000 px)").tag(CGFloat(5000))
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                Text("Outputs a 16-bit uncompressed DNG in the same folder and imports it into your library.")
                    .uiFont(10)
                    .foregroundColor(LightroomTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider().background(LightroomTheme.dividerColor)

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Merge to DNG") {
                    let options = PanoramaMergeOptions(
                        autoCrop: autoCrop,
                        useHomography: useHomography,
                        maxFrameLongEdge: maxFrameLongEdge,
                        outputFilename: outputFilename
                    )
                    dismiss()
                    appState.mergeSelectedPhotosToPanorama(options: options)
                }
                .buttonStyle(.borderedProminent)
                .tint(LightroomTheme.accentYellow)
                .foregroundColor(.black)
                .keyboardShortcut(.defaultAction)
                .disabled(sortedSelected.count < 2)
            }
            .padding()
            .background(LightroomTheme.cardBackground)
        }
        .frame(width: 440)
        .background(LightroomTheme.panelBackground)
        .onAppear {
            if outputFilename.isEmpty, let first = sortedSelected.first {
                let base = (first.filename as NSString).deletingPathExtension
                outputFilename = "\(base)-Pano.dng"
            }
        }
    }
}

import SwiftUI
import AppKit

/// Real-time RGB & Luminance histogram graph
public struct HistogramView: View {
    public let asset: PhotoAsset?
    
    @State private var histogramData: HistogramData = .empty
    @State private var isCalculating: Bool = false
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header stats (ISO, Focal, Aperture, Shutter)
            if let asset = asset {
                HStack {
                    if let iso = asset.cameraMetadata.iso {
                        Text("ISO \(iso)")
                    }
                    if let focal = asset.cameraMetadata.focalLength {
                        Text(String(format: "%.0fmm", focal))
                    }
                    if let f = asset.cameraMetadata.aperture {
                        Text(String(format: "ƒ/%.1f", f))
                    }
                    if let s = asset.cameraMetadata.shutterSpeed {
                        Text(s)
                    }
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(LightroomTheme.textSecondary)
                .padding(.horizontal, 10)
            }
            
            // Histogram Curve Canvas
            ZStack {
                Color.black.opacity(0.6)
                
                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    let step = w / 256.0
                    
                    // Helper to draw channel path
                    func drawChannel(values: [Float], color: Color, opacity: Double) {
                        guard values.count == 256 else { return }
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: h))
                        
                        for i in 0..<256 {
                            let x = CGFloat(i) * step
                            let y = h - (CGFloat(values[i]) * h * 0.95)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                        
                        context.fill(path, with: .color(color.opacity(opacity)))
                        
                        // Stroke top line
                        var strokePath = Path()
                        for i in 0..<256 {
                            let x = CGFloat(i) * step
                            let y = h - (CGFloat(values[i]) * h * 0.95)
                            if i == 0 {
                                strokePath.move(to: CGPoint(x: x, y: y))
                            } else {
                                strokePath.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        context.stroke(strokePath, with: .color(color), lineWidth: 1.0)
                    }
                    
                    // Draw base gray luminance shape first
                    drawChannel(values: histogramData.luminance, color: Color(white: 0.75), opacity: 0.35)
                    
                    // Draw RGB channels with vibrant Lightroom tones
                    drawChannel(values: histogramData.red, color: Color(red: 0.95, green: 0.25, blue: 0.20), opacity: 0.35)
                    drawChannel(values: histogramData.green, color: Color(red: 0.20, green: 0.85, blue: 0.30), opacity: 0.35)
                    drawChannel(values: histogramData.blue, color: Color(red: 0.15, green: 0.55, blue: 0.95), opacity: 0.40)
                }
            }
            .frame(height: 110)
            .cornerRadius(4)
            .padding(.horizontal, 8)
        }
        .task(id: asset?.id) {
            await computeHistogram()
        }
        .task(id: asset?.xmp) {
            // Debounce histogram during rapid slider drags to keep GPU & CPU dedicated to 120fps preview
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await computeHistogram()
        }
    }
    
    private func computeHistogram() async {
        guard let asset = asset else {
            self.histogramData = .empty
            return
        }
        
        isCalculating = true
        
        // 1. Compute histogram from the actual developed image with all XMP adjustments
        let work = Task.detached {
            guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: asset.fileURL, xmp: asset.xmp),
                  !Task.isCancelled else { return Optional<NSImage>.none }
            return RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: asset.cameraMetadata.model,
                                                        xmp: asset.xmp, interactive: true)
        }
        let processed = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        if let processed {
            let data = await HistogramCalculator.computeHistogram(for: processed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.histogramData = data
                self.isCalculating = false
            }
            return
        }
        
        // 2. Fallback to thumbnail
        if let thumbnail = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 512) {
            let data = await HistogramCalculator.computeHistogram(for: thumbnail)
            await MainActor.run {
                self.histogramData = data
                self.isCalculating = false
            }
        }
    }
}

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
                    
                    // Draw channels with additive blend effect
                    drawChannel(values: histogramData.red, color: Color.red, opacity: 0.3)
                    drawChannel(values: histogramData.green, color: Color.green, opacity: 0.3)
                    drawChannel(values: histogramData.blue, color: Color.blue, opacity: 0.3)
                    drawChannel(values: histogramData.luminance, color: Color.white, opacity: 0.25)
                }
            }
            .frame(height: 110)
            .cornerRadius(4)
            .padding(.horizontal, 8)
        }
        .task(id: asset?.id) {
            await computeHistogram()
        }
    }
    
    private func computeHistogram() async {
        guard let asset = asset else {
            self.histogramData = .empty
            return
        }
        
        isCalculating = true
        if let thumbnail = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 300) {
            let data = await HistogramCalculator.computeHistogram(for: thumbnail)
            await MainActor.run {
                self.histogramData = data
                self.isCalculating = false
            }
        }
    }
}

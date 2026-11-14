import SwiftUI
import AppKit

/// Bins only a published display bitmap. No URL/source loader/render dependency exists.
@MainActor public final class DisplayHistogramState: ObservableObject {
    @Published public private(set) var data: HistogramData?
    @Published public private(set) var label = ""
    public var enabled = false { didSet { if !enabled { clear() } } }
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?
    private let compute: (NSImage) async -> HistogramData
    public init(compute: @escaping (NSImage) async -> HistogramData = { await HistogramCalculator.computeHistogram(for: $0) }) {
        self.compute = compute
    }
    public func clear() {
        revision &+= 1; task?.cancel(); task = nil; data = nil; label = ""
    }
    public func submit(_ image: NSImage, label: String) {
        guard enabled else { return }
        clear()
        let ticket = revision
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.enabled else { return }
            let data = await self.compute(image)
            guard !Task.isCancelled, self.enabled, self.revision == ticket else { return }
            self.data = data; self.label = label; self.task = nil
        }
    }
}

/// Real-time RGB & Luminance histogram graph
public struct HistogramView: View {
    public let asset: PhotoAsset?
    
    @ObservedObject var histogram: DisplayHistogramState
    private var histogramData: HistogramData { histogram.data ?? .empty }
    
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
                .uiFont(10, weight: .medium)
                .foregroundColor(LightroomTheme.textSecondary)
                .padding(.horizontal, 10)
            }
            
            Text(histogram.label.isEmpty ? "Waiting for displayed bitmap" : histogram.label)
                .uiFont(10).padding(.horizontal, 10)
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
    }
}

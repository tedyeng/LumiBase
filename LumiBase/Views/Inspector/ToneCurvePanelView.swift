import SwiftUI

/// Active channel selection for Tone Curve
public enum ToneCurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"
    
    public var id: String { rawValue }
    
    public var strokeColor: Color {
        switch self {
        case .rgb: return Color(white: 0.9)
        case .red: return Color.red
        case .green: return Color.green
        case .blue: return Color.blue
        }
    }
}

/// Interactive Tone Curve Panel View with Cubic Spline Canvas
public struct ToneCurvePanelView: View {
    public let asset: PhotoAsset
    @ObservedObject var appState: AppState
    
    @State private var selectedChannel: ToneCurveChannel = .rgb
    @State private var draggedPointIndex: Int? = nil
    
    public init(asset: PhotoAsset, appState: AppState) {
        self.asset = asset
        self.appState = appState
    }
    
    private var currentXMP: XMPMetadata {
        if appState.liveDevelopAssetID == asset.id, let live = appState.liveDevelopXMP {
            return live
        }
        return asset.xmp
    }
    
    private var activePoints: [ToneCurvePoint] {
        switch selectedChannel {
        case .rgb: return currentXMP.toneCurve.rgbPoints
        case .red: return currentXMP.toneCurve.redPoints
        case .green: return currentXMP.toneCurve.greenPoints
        case .blue: return currentXMP.toneCurve.bluePoints
        }
    }
    
    private func updateActivePoints(_ points: [ToneCurvePoint], isDragging: Bool) {
        let sorted = points.sorted()
        appState.updateDevelopSettings(for: asset.id, isDragging: isDragging) { xmp in
            switch selectedChannel {
            case .rgb: xmp.toneCurve.rgbPoints = sorted
            case .red: xmp.toneCurve.redPoints = sorted
            case .green: xmp.toneCurve.greenPoints = sorted
            case .blue: xmp.toneCurve.bluePoints = sorted
            }
        }
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            
            // Channel & Preset Selector Header
            HStack(spacing: 8) {
                // Channel Picker
                Picker("", selection: $selectedChannel) {
                    ForEach(ToneCurveChannel.allCases) { ch in
                        Text(ch.rawValue).tag(ch)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                
                Spacer()
                
                // Curve Presets Menu
                Menu {
                    Button("Linear") {
                        updateActivePoints(ToneCurveData.linearPoints, isDragging: false)
                    }
                    Button("Medium Contrast") {
                        updateActivePoints(ToneCurveData.mediumContrastPoints, isDragging: false)
                    }
                    Button("Strong Contrast") {
                        updateActivePoints(ToneCurveData.strongContrastPoints, isDragging: false)
                    }
                    Divider()
                    Button("Reset Channel") {
                        updateActivePoints(ToneCurveData.linearPoints, isDragging: false)
                    }
                    Button("Reset All Curves") {
                        appState.updateDevelopSettings(for: asset.id, isDragging: false) {
                            $0.toneCurve = .linear
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 9))
                        Text("Presets")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(LightroomTheme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(LightroomTheme.cardBackground)
                    .cornerRadius(3)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 10)
            
            // Interactive Curve Canvas
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let canvasRect = CGRect(x: (geo.size.width - size) / 2, y: 0, width: size, height: size)
                
                ZStack {
                    // Background & Grid
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(LightroomTheme.dividerColor, lineWidth: 1)
                        )
                    
                    // Grid lines (quarter divisions)
                    Path { path in
                        for i in 1...3 {
                            let f = CGFloat(i) / 4.0
                            let x = canvasRect.minX + f * size
                            let y = canvasRect.minY + f * size
                            // Vertical
                            path.move(to: CGPoint(x: x, y: canvasRect.minY))
                            path.addLine(to: CGPoint(x: x, y: canvasRect.maxY))
                            // Horizontal
                            path.move(to: CGPoint(x: canvasRect.minX, y: y))
                            path.addLine(to: CGPoint(x: canvasRect.maxX, y: y))
                        }
                        // Diagonal Identity Reference
                        path.move(to: CGPoint(x: canvasRect.minX, y: canvasRect.maxY))
                        path.addLine(to: CGPoint(x: canvasRect.maxX, y: canvasRect.minY))
                    }
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    
                    // Background channel reference curves when viewing Master RGB
                    if selectedChannel == .rgb {
                        ForEach([ToneCurveChannel.red, .green, .blue]) { ch in
                            let chPoints: [ToneCurvePoint] = {
                                switch ch {
                                case .red: return currentXMP.toneCurve.redPoints
                                case .green: return currentXMP.toneCurve.greenPoints
                                case .blue: return currentXMP.toneCurve.bluePoints
                                case .rgb: return []
                                }
                            }()
                            if chPoints != ToneCurveData.linearPoints {
                                let chLut = ToneCurveData.evaluateLUT(for: chPoints)
                                Path { path in
                                    guard chLut.count == 256 else { return }
                                    for i in 0..<256 {
                                        let px = canvasRect.minX + (CGFloat(i) / 255.0) * size
                                        let py = canvasRect.minY + (1.0 - CGFloat(chLut[i])) * size
                                        if i == 0 {
                                            path.move(to: CGPoint(x: px, y: py))
                                        } else {
                                            path.addLine(to: CGPoint(x: px, y: py))
                                        }
                                    }
                                }
                                .stroke(ch.strokeColor.opacity(0.45), lineWidth: 1.1)
                            }
                        }
                    }
                    
                    // Spline Curve Line
                    let lut = ToneCurveData.evaluateLUT(for: activePoints)
                    Path { path in
                        guard lut.count == 256 else { return }
                        for i in 0..<256 {
                            let px = canvasRect.minX + (CGFloat(i) / 255.0) * size
                            let py = canvasRect.minY + (1.0 - CGFloat(lut[i])) * size
                            if i == 0 {
                                path.move(to: CGPoint(x: px, y: py))
                            } else {
                                path.addLine(to: CGPoint(x: px, y: py))
                            }
                        }
                    }
                    .stroke(selectedChannel.strokeColor, lineWidth: 1.8)
                    
                    // Control Points
                    ForEach(0..<activePoints.count, id: \.self) { idx in
                        let pt = activePoints[idx]
                        let px = canvasRect.minX + (CGFloat(pt.x) / 255.0) * size
                        let py = canvasRect.minY + (1.0 - (CGFloat(pt.y) / 255.0)) * size
                        
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(selectedChannel.strokeColor, lineWidth: 1.5))
                            .shadow(radius: 2)
                            .position(x: px, y: py)
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        var updated = activePoints
                                        guard idx < updated.count else { return }
                                        let nx = Double((value.location.x - canvasRect.minX) / size) * 255.0
                                        let ny = Double(1.0 - ((value.location.y - canvasRect.minY) / size)) * 255.0
                                        
                                        // Endpoints x is locked to 0 and 255; interior points are clamped between neighbors
                                        if idx == 0 {
                                            updated[idx] = ToneCurvePoint(x: 0, y: ny)
                                        } else if idx == updated.count - 1 {
                                            updated[idx] = ToneCurvePoint(x: 255, y: ny)
                                        } else {
                                            let minX = updated[idx - 1].x + 2.0
                                            let maxX = updated[idx + 1].x - 2.0
                                            let clampedX = min(maxX, max(minX, nx))
                                            updated[idx] = ToneCurvePoint(x: clampedX, y: ny)
                                        }
                                        updateActivePoints(updated, isDragging: true)
                                    }
                                    .onEnded { _ in
                                        updateActivePoints(activePoints, isDragging: false)
                                    }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    // Remove point on double tap if not endpoint
                                    if idx > 0 && idx < activePoints.count - 1 {
                                        var updated = activePoints
                                        updated.remove(at: idx)
                                        updateActivePoints(updated, isDragging: false)
                                    }
                                }
                            )
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { event in
                        let clickLoc = event.location
                        guard canvasRect.contains(clickLoc) else { return }
                        let nx = Double((clickLoc.x - canvasRect.minX) / size) * 255.0
                        let ny = Double(1.0 - ((clickLoc.y - canvasRect.minY) / size)) * 255.0
                        
                        // Add new point if not close to existing point
                        let existingClose = activePoints.contains { abs($0.x - nx) < 15 }
                        if !existingClose && activePoints.count < 10 {
                            var updated = activePoints
                            updated.append(ToneCurvePoint(x: nx, y: ny))
                            updateActivePoints(updated, isDragging: false)
                        }
                    }
                )
            }
            .frame(height: 180)
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
    }
}

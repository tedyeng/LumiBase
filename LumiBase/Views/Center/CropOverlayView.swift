import SwiftUI

public enum CropHandle: CaseIterable {
    case topLeft, topMid, topRight
    case midLeft, midRight
    case bottomLeft, bottomMid, bottomRight
}

/// Interactive 8-point crop overlay with Rule of Thirds grid and aspect ratio enforcement
public struct CropOverlayView: View {
    public let imageSize: CGSize
    public let containerSize: CGSize
    @ObservedObject var appState: AppState
    
    @State private var isDragging: Bool = false
    @State private var activeHandle: CropHandle?
    @State private var dragInitialGeometry: CropGeometry?
    
    public init(imageSize: CGSize, containerSize: CGSize, appState: AppState) {
        self.imageSize = imageSize
        self.containerSize = containerSize
        self.appState = appState
    }
    
    private var imageDisplayRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let dispW = imageSize.width * scale
        let dispH = imageSize.height * scale
        let originX = (containerSize.width - dispW) / 2.0
        let originY = (containerSize.height - dispH) / 2.0
        return CGRect(x: originX, y: originY, width: dispW, height: dispH)
    }
    
    private var currentGeometry: CropGeometry {
        if let live = appState.liveDevelopXMP {
            return live.cropGeometry
        }
        return appState.primarySelectedAsset?.xmp.cropGeometry ?? .full
    }
    
    private func cropRect(in imgRect: CGRect) -> CGRect {
        let g = currentGeometry
        let x = imgRect.minX + (g.left * imgRect.width)
        let y = imgRect.minY + (g.top * imgRect.height)
        let w = g.widthFraction * imgRect.width
        let h = g.heightFraction * imgRect.height
        return CGRect(x: x, y: y, width: max(20, w), height: max(20, h))
    }
    
    public var body: some View {
        let imgRect = imageDisplayRect
        let cRect = cropRect(in: imgRect)
        
        ZStack {
            // 1. Darkened outer mask (4 surrounding boxes)
            outerDimmedMask(containerSize: containerSize, cropRect: cRect)
            
            // 2. Crop Box Border & Grid
            ZStack {
                // Outer Crop Rect Stroke
                Rectangle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
                
                // Crop Overlay Guide: Multi-line adaptive Alignment Grid or Rule of Thirds (3x3)
                if appState.cropOverlayStyle == .grid {
                    adaptiveAlignmentGrid(size: cRect.size)
                } else {
                    ruleOfThirdsGrid
                }
                
                // 3. Center Pan Drag Area
                Rectangle()
                    .fill(Color.black.opacity(0.001)) // Transparent hit target
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                handlePanDrag(translation: value.translation, imgRect: imgRect)
                            }
                            .onEnded { _ in
                                handleDragEnd()
                            }
                    )
            }
            .frame(width: cRect.width, height: cRect.height)
            .position(x: cRect.midX, y: cRect.midY)
            
            // 4. 8 Draggable Corner and Edge Handles
            ForEach(CropHandle.allCases, id: \.self) { handle in
                cropHandleView(for: handle, cropRect: cRect, imgRect: imgRect)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
    }
    
    // MARK: - Mask Subviews
    
    private func outerDimmedMask(containerSize: CGSize, cropRect: CGRect) -> some View {
        Canvas { context, size in
            let fullRect = CGRect(origin: .zero, size: size)
            context.fill(Path(fullRect), with: .color(Color.black.opacity(0.55)))
            context.blendMode = .clear
            context.fill(Path(cropRect), with: .color(.black))
        }
        .allowsHitTesting(false)
    }
    
    /// Lightroom Classic-style multi-line alignment grid that dynamically scales grid lines according to window / crop box size
    private func adaptiveAlignmentGrid(size: CGSize) -> some View {
        Canvas { context, sz in
            guard sz.width > 0, sz.height > 0 else { return }
            
            // Target cell density (~32pt per grid square)
            let targetCellSize: CGFloat = 32.0
            let numCols = max(4, Int(round(sz.width / targetCellSize)))
            let stepX = sz.width / CGFloat(numCols)
            
            let numRows = max(4, Int(round(sz.height / targetCellSize)))
            let stepY = sz.height / CGFloat(numRows)
            
            var path = Path()
            
            if numCols > 1 {
                for i in 1..<numCols {
                    let x = CGFloat(i) * stepX
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: sz.height))
                }
            }
            
            if numRows > 1 {
                for j in 1..<numRows {
                    let y = CGFloat(j) * stepY
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: sz.width, y: y))
                }
            }
            
            let strokeColor = Color.white.opacity(isDragging ? 0.65 : 0.35)
            context.stroke(path, with: .color(strokeColor), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
    
    private var ruleOfThirdsGrid: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                // 2 Vertical lines
                path.move(to: CGPoint(x: w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w / 3.0, y: h))
                path.move(to: CGPoint(x: w * 2.0 / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w * 2.0 / 3.0, y: h))
                
                // 2 Horizontal lines
                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: h * 2.0 / 3.0))
                path.addLine(to: CGPoint(x: w, y: h * 2.0 / 3.0))
            }
            .stroke(Color.white.opacity(isDragging ? 0.65 : 0.35), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
    
    // MARK: - Handles
    
    private func cropHandleView(for handle: CropHandle, cropRect: CGRect, imgRect: CGRect) -> some View {
        let pos = handlePosition(for: handle, cropRect: cropRect)
        let isCorner = (handle == .topLeft || handle == .topRight || handle == .bottomLeft || handle == .bottomRight)
        
        return ZStack {
            if isCorner {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(
                        width: (handle == .topMid || handle == .bottomMid) ? 24 : 6,
                        height: (handle == .topMid || handle == .bottomMid) ? 6 : 24
                    )
                    .overlay(Capsule().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .position(pos)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    handleResizeDrag(handle: handle, translation: value.translation, imgRect: imgRect)
                }
                .onEnded { _ in
                    handleDragEnd()
                }
        )
    }
    
    private func handlePosition(for handle: CropHandle, cropRect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .topMid: return CGPoint(x: cropRect.midX, y: cropRect.minY)
        case .topRight: return CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .midLeft: return CGPoint(x: cropRect.minX, y: cropRect.midY)
        case .midRight: return CGPoint(x: cropRect.maxX, y: cropRect.midY)
        case .bottomLeft: return CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottomMid: return CGPoint(x: cropRect.midX, y: cropRect.maxY)
        case .bottomRight: return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }
    }
    
    // MARK: - Drag Handlers
    
    private func handlePanDrag(translation: CGSize, imgRect: CGRect) {
        if dragInitialGeometry == nil {
            dragInitialGeometry = currentGeometry
            isDragging = true
        }
        guard let initial = dragInitialGeometry, imgRect.width > 0, imgRect.height > 0 else { return }
        
        let deltaX = Double(translation.width / imgRect.width)
        let deltaY = Double(translation.height / imgRect.height)
        let width = initial.widthFraction
        let height = initial.heightFraction
        
        var newLeft = initial.left + deltaX
        var newTop = initial.top + deltaY
        
        // Clamp bounds
        newLeft = max(0.0, min(1.0 - width, newLeft))
        newTop = max(0.0, min(1.0 - height, newTop))
        
        let newGeom = CropGeometry(
            top: newTop,
            left: newLeft,
            bottom: newTop + height,
            right: newLeft + width,
            angle: initial.angle
        )
        appState.updateCropGeometry(newGeom, isDragging: true)
    }
    
    private func handleResizeDrag(handle: CropHandle, translation: CGSize, imgRect: CGRect) {
        if dragInitialGeometry == nil {
            dragInitialGeometry = currentGeometry
            activeHandle = handle
            isDragging = true
        }
        guard let initial = dragInitialGeometry, imgRect.width > 0, imgRect.height > 0 else { return }
        
        let dx = Double(translation.width / imgRect.width)
        let dy = Double(translation.height / imgRect.height)
        
        var top = initial.top
        var left = initial.left
        var bottom = initial.bottom
        var right = initial.right
        
        switch handle {
        case .topLeft:
            left = max(0.0, min(initial.right - 0.05, initial.left + dx))
            top = max(0.0, min(initial.bottom - 0.05, initial.top + dy))
        case .topMid:
            top = max(0.0, min(initial.bottom - 0.05, initial.top + dy))
        case .topRight:
            right = min(1.0, max(initial.left + 0.05, initial.right + dx))
            top = max(0.0, min(initial.bottom - 0.05, initial.top + dy))
        case .midLeft:
            left = max(0.0, min(initial.right - 0.05, initial.left + dx))
        case .midRight:
            right = min(1.0, max(initial.left + 0.05, initial.right + dx))
        case .bottomLeft:
            left = max(0.0, min(initial.right - 0.05, initial.left + dx))
            bottom = min(1.0, max(initial.top + 0.05, initial.bottom + dy))
        case .bottomMid:
            bottom = min(1.0, max(initial.top + 0.05, initial.bottom + dy))
        case .bottomRight:
            right = min(1.0, max(initial.left + 0.05, initial.right + dx))
            bottom = min(1.0, max(initial.top + 0.05, initial.bottom + dy))
        }
        
        // Apply Aspect Ratio Constraint if locked
        if appState.isCropAspectLocked, let ratio = appState.cropAspectRatioPreset.ratio(originalWidth: imageSize.width, originalHeight: imageSize.height) {
            let imgAspect = imageSize.width / max(1, imageSize.height)
            let desiredFractionRatio = ratio / imgAspect
            
            let curW = right - left
            let curH = bottom - top
            
            if handle == .topMid || handle == .bottomMid {
                let targetW = min(1.0, curH * desiredFractionRatio)
                let center = (left + right) / 2.0
                left = max(0.0, center - targetW / 2.0)
                right = min(1.0, left + targetW)
            } else {
                let targetH = min(1.0, curW / desiredFractionRatio)
                if handle == .topLeft || handle == .topRight {
                    top = max(0.0, bottom - targetH)
                } else {
                    bottom = min(1.0, top + targetH)
                }
            }
        }
        
        let newGeom = CropGeometry(
            top: top,
            left: left,
            bottom: bottom,
            right: right,
            angle: initial.angle
        )
        appState.updateCropGeometry(newGeom, isDragging: true)
    }
    
    private func handleDragEnd() {
        if dragInitialGeometry != nil {
            appState.updateCropGeometry(currentGeometry, isDragging: false)
        }
        dragInitialGeometry = nil
        activeHandle = nil
        isDragging = false
    }
}

import SwiftUI
import AppKit

public enum CropHandle: CaseIterable {
    case topLeft, topMid, topRight
    case midLeft, midRight
    case bottomLeft, bottomMid, bottomRight
}

/// Interactive 8-point crop overlay with Rule of Thirds grid, aspect ratio enforcement, and edge/corner rotation
public struct CropOverlayView: View {
    public let imageSize: CGSize
    public let containerSize: CGSize
    @ObservedObject var appState: AppState
    
    @State private var isDragging: Bool = false
    @State private var activeHandle: CropHandle?
    @State private var dragInitialGeometry: CropGeometry?
    @State private var dragLiveGeometry: CropGeometry?
    @State private var dragGridCounts: (cols: Int, rows: Int)?
    
    // Direct canvas rotation (drag outside crop box or along border between handles)
    @State private var isRotating: Bool = false
    @State private var rotateInitialAngle: Double?
    @State private var rotateLastVectorAngle: Double?
    @State private var rotateAccumulatedRadians: Double = 0.0
    @State private var rotateLiveAngle: Double?
    @State private var rotateDidChange: Bool = false
    @State private var isHoveringRotateZone: Bool = false
    @State private var rotateCursorSector: Int = 0
    @State private var pushedRotateCursorSector: Int? = nil
    
    private static let coordinateSpaceName = "CropOverlayCoordinateSpace"
    private static let handleHitSize: CGFloat = 28.0
    private static let maxBorderRotateInset: CGFloat = 8.0
    
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
    
    private var committedGeometry: CropGeometry {
        if let live = appState.liveDevelopXMP {
            return live.cropGeometry
        }
        return appState.primarySelectedAsset?.xmp.cropGeometry ?? .full
    }
    
    private var currentGeometry: CropGeometry {
        dragLiveGeometry ?? committedGeometry
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
        let borderRotateInset = Self.borderRotateInset(for: cRect)
        
        ZStack {
            // 0. Outer & Border Rotation Drag Area (behind interior pan area and 8 resize handles)
            Color.black.opacity(0.001)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                        .onChanged { value in
                            handleRotateDrag(
                                location: value.location,
                                startLocation: value.startLocation,
                                imgRect: imgRect
                            )
                        }
                        .onEnded { _ in
                            handleRotateEnd()
                        }
                )
            
            // 1. Darkened outer mask (4 surrounding boxes)
            outerDimmedMask(containerSize: containerSize, cropRect: cRect)
            
            // 2. Crop Box Border & Grid
            ZStack {
                // Outer Crop Rect Stroke
                Rectangle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
                    .allowsHitTesting(false)
                
                // Crop Overlay Guide: Multi-line adaptive Alignment Grid or Rule of Thirds (3x3)
                if appState.cropOverlayStyle == .grid {
                    adaptiveAlignmentGrid(size: cRect.size)
                } else {
                    ruleOfThirdsGrid
                }
                
                // 3. Center Pan Drag Area (inset slightly so border edges between handles also rotate)
                Rectangle()
                    .fill(Color.black.opacity(0.001)) // Transparent hit target
                    .padding(borderRotateInset)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
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
            
            // 5. Live Angle HUD Badge while rotating on canvas
            if isRotating {
                rotateAngleBadge(angle: rotateLiveAngle ?? currentGeometry.angle)
                    .position(x: cRect.midX, y: max(28, cRect.minY + 28))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(Self.coordinateSpaceName)) { phase in
            switch phase {
            case .active(let location):
                let inRotateZone = Self.isPointInRotateZone(location, cropRect: cRect)
                isHoveringRotateZone = inRotateZone
                if inRotateZone {
                    rotateCursorSector = Self.rotateCursorSector(
                        for: location,
                        center: CGPoint(x: cRect.midX, y: cRect.midY)
                    )
                }
                syncRotateCursor()
            case .ended:
                isHoveringRotateZone = false
                syncRotateCursor()
            }
        }
        .onChange(of: isRotating) { _, _ in
            syncRotateCursor()
        }
        .onDisappear {
            popRotateCursorIfNeeded()
        }
        .onChange(of: committedGeometry) { _, _ in
            if !isDragging {
                dragLiveGeometry = nil
            }
        }
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
            
            // Target cell density (~32pt per grid square); lock cell count during active drag to prevent line popping
            let targetCellSize: CGFloat = 32.0
            let numCols = dragGridCounts?.cols ?? max(4, Int(round(sz.width / targetCellSize)))
            let stepX = sz.width / CGFloat(numCols)
            
            let numRows = dragGridCounts?.rows ?? max(4, Int(round(sz.height / targetCellSize)))
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
        .frame(width: Self.handleHitSize, height: Self.handleHitSize)
        .contentShape(Rectangle())
        .position(pos)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                .onChanged { value in
                    handleResizeDrag(handle: handle, translation: value.translation, imgRect: imgRect)
                }
                .onEnded { _ in
                    handleDragEnd()
                }
        )
    }
    
    private func handlePosition(for handle: CropHandle, cropRect: CGRect) -> CGPoint {
        Self.handlePosition(for: handle, cropRect: cropRect)
    }
    
    public static func handlePosition(for handle: CropHandle, cropRect: CGRect) -> CGPoint {
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
            let initial = currentGeometry
            dragInitialGeometry = initial
            let initW = initial.widthFraction * imgRect.width
            let initH = initial.heightFraction * imgRect.height
            dragGridCounts = (
                cols: max(4, Int(round(initW / 32.0))),
                rows: max(4, Int(round(initH / 32.0)))
            )
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
        
        dragLiveGeometry = CropGeometry(
            top: newTop,
            left: newLeft,
            bottom: newTop + height,
            right: newLeft + width,
            angle: initial.angle
        )
    }
    
    private func handleResizeDrag(handle: CropHandle, translation: CGSize, imgRect: CGRect) {
        if dragInitialGeometry == nil {
            let initial = currentGeometry
            dragInitialGeometry = initial
            let initW = initial.widthFraction * imgRect.width
            let initH = initial.heightFraction * imgRect.height
            dragGridCounts = (
                cols: max(4, Int(round(initW / 32.0))),
                rows: max(4, Int(round(initH / 32.0)))
            )
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
            let desiredFractionRatio = Double(ratio / imgAspect)
            
            if handle == .topMid || handle == .bottomMid {
                var curH = bottom - top
                var targetW = curH * desiredFractionRatio
                if targetW > 1.0 {
                    targetW = 1.0
                    curH = targetW / desiredFractionRatio
                    if handle == .topMid {
                        top = bottom - curH
                    } else {
                        bottom = top + curH
                    }
                }
                let centerX = (initial.left + initial.right) / 2.0
                left = max(0.0, min(1.0 - targetW, centerX - targetW / 2.0))
                right = left + targetW
            } else if handle == .midLeft || handle == .midRight {
                var curW = right - left
                var targetH = curW / desiredFractionRatio
                if targetH > 1.0 {
                    targetH = 1.0
                    curW = targetH * desiredFractionRatio
                    if handle == .midLeft {
                        left = right - curW
                    } else {
                        right = left + curW
                    }
                }
                let centerY = (initial.top + initial.bottom) / 2.0
                top = max(0.0, min(1.0 - targetH, centerY - targetH / 2.0))
                bottom = top + targetH
            } else {
                // Corner handles: anchor opposite corner and clamp to image boundaries
                let maxW = (handle == .topLeft || handle == .bottomLeft) ? initial.right : (1.0 - initial.left)
                let maxH = (handle == .topLeft || handle == .topRight) ? initial.bottom : (1.0 - initial.top)
                
                var w = min(maxW, max(0.05, right - left))
                var h = w / desiredFractionRatio
                if h > maxH {
                    h = maxH
                    w = h * desiredFractionRatio
                }
                if h < 0.05 {
                    h = 0.05
                    w = min(maxW, h * desiredFractionRatio)
                }
                
                if handle == .topLeft || handle == .bottomLeft {
                    left = initial.right - w
                    right = initial.right
                } else {
                    left = initial.left
                    right = initial.left + w
                }
                
                if handle == .topLeft || handle == .topRight {
                    top = initial.bottom - h
                    bottom = initial.bottom
                } else {
                    top = initial.top
                    bottom = initial.top + h
                }
            }
        }
        
        dragLiveGeometry = CropGeometry(
            top: top,
            left: left,
            bottom: bottom,
            right: right,
            angle: initial.angle
        )
    }
    
    private func handleDragEnd() {
        if let finalGeometry = dragLiveGeometry {
            appState.updateCropGeometry(finalGeometry, isDragging: false)
        } else if dragInitialGeometry != nil {
            appState.updateCropGeometry(currentGeometry, isDragging: false)
        }
        dragInitialGeometry = nil
        dragLiveGeometry = nil
        dragGridCounts = nil
        activeHandle = nil
        isDragging = false
    }
    
    // MARK: - Direct Canvas Rotation
    
    private func handleRotateDrag(location: CGPoint, startLocation: CGPoint, imgRect: CGRect) {
        let pivot = CGPoint(x: imgRect.midX, y: imgRect.midY)
        
        if rotateInitialAngle == nil {
            let startDx = Double(startLocation.x - pivot.x)
            let startDy = Double(startLocation.y - pivot.y)
            guard hypot(startDx, startDy) >= 10.0 else { return }
            
            let initial = currentGeometry
            rotateInitialAngle = initial.angle
            rotateLastVectorAngle = atan2(startDy, startDx)
            rotateAccumulatedRadians = 0.0
            rotateLiveAngle = initial.angle
            rotateDidChange = false
            
            let initW = initial.widthFraction * imgRect.width
            let initH = initial.heightFraction * imgRect.height
            dragGridCounts = (
                cols: max(4, Int(round(initW / 32.0))),
                rows: max(4, Int(round(initH / 32.0)))
            )
            isRotating = true
            isDragging = true
        }
        
        guard let initialAngle = rotateInitialAngle, let lastAngle = rotateLastVectorAngle else { return }
        let dx = Double(location.x - pivot.x)
        let dy = Double(location.y - pivot.y)
        guard hypot(dx, dy) >= 10.0 else { return }
        
        let currentVectorAngle = atan2(dy, dx)
        let stepDelta = Self.wrappedAngleDeltaRadians(from: lastAngle, to: currentVectorAngle)
        rotateLastVectorAngle = currentVectorAngle
        rotateAccumulatedRadians += stepDelta
        
        rotateCursorSector = Self.rotateCursorSector(for: location, center: pivot)
        syncRotateCursor()
        
        let newAngle = Self.updatedCropAngle(
            initialAngle: initialAngle,
            accumulatedDeltaRadians: rotateAccumulatedRadians
        )
        if newAngle != rotateLiveAngle {
            rotateLiveAngle = newAngle
            rotateDidChange = true
            appState.updateCropAngle(newAngle, isDragging: true)
        }
    }
    
    private func handleRotateEnd() {
        if rotateDidChange, let finalAngle = rotateLiveAngle {
            appState.updateCropAngle(finalAngle, isDragging: false)
        }
        rotateInitialAngle = nil
        rotateLastVectorAngle = nil
        rotateAccumulatedRadians = 0.0
        rotateLiveAngle = nil
        rotateDidChange = false
        dragGridCounts = nil
        isRotating = false
        isDragging = false
    }
    
    private func rotateAngleBadge(angle: Double) -> some View {
        Text(String(format: "%+.1f°", angle == 0 ? 0.0 : angle))
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
    }
    
    // MARK: - Rotate Zone Hit-Testing & Math
    
    public static func borderRotateInset(for cropRect: CGRect) -> CGFloat {
        min(maxBorderRotateInset, min(cropRect.width, cropRect.height) * 0.15)
    }
    
    /// Returns true when `point` is outside the crop box or on its border strip between resize handles.
    public static func isPointInRotateZone(_ point: CGPoint, cropRect: CGRect) -> Bool {
        let halfHandle = handleHitSize / 2.0
        for handle in CropHandle.allCases {
            let pos = handlePosition(for: handle, cropRect: cropRect)
            let handleRect = CGRect(
                x: pos.x - halfHandle,
                y: pos.y - halfHandle,
                width: handleHitSize,
                height: handleHitSize
            )
            if handleRect.contains(point) {
                return false
            }
        }
        let inset = borderRotateInset(for: cropRect)
        let panRect = cropRect.insetBy(dx: inset, dy: inset)
        return !panRect.contains(point)
    }
    
    /// Shortest signed angular delta in radians (-pi...pi) to avoid discontinuities across the -pi/+pi seam.
    public static func wrappedAngleDeltaRadians(from previous: Double, to current: Double) -> Double {
        atan2(sin(current - previous), cos(current - previous))
    }
    
    /// Converts accumulated screen-space clockwise delta radians (SwiftUI Y-down) into clamped XMP cropAngle (-45...45 deg).
    public static func updatedCropAngle(initialAngle: Double, accumulatedDeltaRadians: Double) -> Double {
        let deltaDegrees = accumulatedDeltaRadians * 180.0 / .pi
        let raw = max(-45.0, min(45.0, initialAngle - deltaDegrees))
        let rounded = (raw * 10.0).rounded() / 10.0
        return abs(rounded) < 0.05 ? 0.0 : rounded
    }
    
    /// Quantizes the pointer's radial direction around `center` (SwiftUI Y-down) into 8 sectors:
    /// 0 = right, 1 = top-right, 2 = top, 3 = top-left, 4 = left, 5 = bottom-left, 6 = bottom, 7 = bottom-right.
    public static func rotateCursorSector(for point: CGPoint, center: CGPoint) -> Int {
        let dx = Double(point.x - center.x)
        let dy = Double(-(point.y - center.y)) // Convert SwiftUI Y-down to standard Y-up
        var deg = atan2(dy, dx) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return Int(((deg + 22.5).truncatingRemainder(dividingBy: 360.0)) / 45.0) % 8
    }
    
    // MARK: - Rotate Cursor
    
    private func syncRotateCursor() {
        let shouldShowRotate = isHoveringRotateZone || isRotating
        if shouldShowRotate {
            if pushedRotateCursorSector == rotateCursorSector { return }
            if pushedRotateCursorSector != nil {
                NSCursor.pop()
            }
            Self.rotateCursors[rotateCursorSector].push()
            pushedRotateCursorSector = rotateCursorSector
        } else if pushedRotateCursorSector != nil {
            NSCursor.pop()
            pushedRotateCursorSector = nil
        }
    }
    
    private func popRotateCursorIfNeeded() {
        if pushedRotateCursorSector != nil {
            NSCursor.pop()
            pushedRotateCursorSector = nil
        }
        isHoveringRotateZone = false
    }
    
    private static let rotateCursors: [NSCursor] = (0..<8).map { sector in
        makeRotateCursor(centerDegrees: CGFloat(sector) * 45.0)
    }
    
    private static func makeRotateCursor(centerDegrees: CGFloat) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            let centerRad = centerDegrees * .pi / 180.0
            let arcCenter = NSPoint(
                x: 12.0 - 2.5 * cos(centerRad),
                y: 12.0 - 2.5 * sin(centerRad)
            )
            let radius: CGFloat = 7.2
            let startDeg: CGFloat = centerDegrees - 55.0
            let endDeg: CGFloat = centerDegrees + 55.0
            
            func buildArrowPath() -> NSBezierPath {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.appendArc(withCenter: arcCenter, radius: radius, startAngle: startDeg, endAngle: endDeg, clockwise: false)
                
                // Arrowhead at endDeg (CCW tip)
                let endRad = endDeg * .pi / 180.0
                let endTip = NSPoint(x: arcCenter.x + radius * cos(endRad), y: arcCenter.y + radius * sin(endRad))
                let endTangent = endRad + .pi / 2.0
                let headLen: CGFloat = 3.8
                let spread: CGFloat = 0.62
                path.move(to: NSPoint(x: endTip.x - headLen * cos(endTangent - spread), y: endTip.y - headLen * sin(endTangent - spread)))
                path.line(to: endTip)
                path.line(to: NSPoint(x: endTip.x - headLen * cos(endTangent + spread), y: endTip.y - headLen * sin(endTangent + spread)))
                
                // Arrowhead at startDeg (CW tip)
                let startRad = startDeg * .pi / 180.0
                let startTip = NSPoint(x: arcCenter.x + radius * cos(startRad), y: arcCenter.y + radius * sin(startRad))
                let startTangent = startRad - .pi / 2.0
                path.move(to: NSPoint(x: startTip.x - headLen * cos(startTangent - spread), y: startTip.y - headLen * sin(startTangent - spread)))
                path.line(to: startTip)
                path.line(to: NSPoint(x: startTip.x - headLen * cos(startTangent + spread), y: startTip.y - headLen * sin(startTangent + spread)))
                
                return path
            }
            
            let halo = buildArrowPath()
            halo.lineWidth = 3.6
            NSColor.white.setStroke()
            halo.stroke()
            
            let core = buildArrowPath()
            core.lineWidth = 1.6
            NSColor.black.setStroke()
            core.stroke()
            
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
}

/// Interactive Lightroom-style Spot Removal / Healing overlay
public struct HealOverlayView: View {
    let imageSize: CGSize
    let crop: CropGeometry
    let spots: [SpotHealEntry]
    @ObservedObject var appState: AppState

    enum DragRole {
        case target(SpotHealEntry)
        case source(SpotHealEntry)
    }

    @State private var hoverLocation: CGPoint? = nil
    @State private var activeDrag: DragRole? = nil
    @State private var liveDragSpot: SpotHealEntry? = nil

    private var cropW: Double { max(0.001, crop.right - crop.left) }
    private var cropH: Double { max(0.001, crop.bottom - crop.top) }
    private var fullWidthPt: Double { Double(max(imageSize.width, 1)) / cropW }

    private func toLocal(_ nx: Double, _ ny: Double) -> CGPoint {
        let u = (nx - crop.left) / cropW
        let v = (ny - crop.top) / cropH
        return CGPoint(x: u * Double(imageSize.width), y: v * Double(imageSize.height))
    }

    private func toNormalized(_ pt: CGPoint) -> (Double, Double) {
        let u = Double(pt.x) / Double(max(imageSize.width, 1))
        let v = Double(pt.y) / Double(max(imageSize.height, 1))
        let nx = max(0.002, min(0.998, crop.left + u * cropW))
        let ny = max(0.002, min(0.998, crop.top + v * cropH))
        return (nx, ny)
    }

    public var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            if appState.isHealOverlayVisible {
                // Draw all spots
                ForEach(spots) { baseSpot in
                    let spot = (liveDragSpot?.id == baseSpot.id) ? (liveDragSpot ?? baseSpot) : baseSpot
                    let isSelected = (appState.selectedSpotHealID == spot.id)
                    let targetPt = toLocal(spot.targetX, spot.targetY)
                    let sourcePt = toLocal(spot.sourceX, spot.sourceY)
                    let rPt = max(6.0, spot.radius * fullWidthPt)

                    if isSelected {
                        // Connecting line from source to target
                        Path { path in
                            path.move(to: sourcePt)
                            path.addLine(to: targetPt)
                        }
                        .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.2))

                        // Source circle (dashed)
                        Circle()
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: rPt * 2, height: rPt * 2)
                            .position(sourcePt)
                    }

                    // Target circle
                    Circle()
                        .stroke(isSelected ? LightroomTheme.accentYellow : Color.white.opacity(0.75), lineWidth: isSelected ? 2.0 : 1.3)
                        .background(Circle().fill(Color.white.opacity(isSelected ? 0.08 : 0.02)))
                        .frame(width: rPt * 2, height: rPt * 2)
                        .position(targetPt)
                }
            }

            // Live brush hover ring
            if let hover = hoverLocation, activeDrag == nil {
                let brushR = max(6.0, appState.healBrushRadius * fullWidthPt)
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.2)
                    .frame(width: brushR * 2, height: brushR * 2)
                    .position(hover)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                hoverLocation = loc
            case .ended:
                hoverLocation = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if activeDrag == nil {
                        // Hit-test existing spots on initial press
                        let loc = value.startLocation
                        if let selectedID = appState.selectedSpotHealID,
                           let selected = spots.first(where: { $0.id == selectedID }) {
                            let sPt = toLocal(selected.sourceX, selected.sourceY)
                            let rPt = max(12.0, selected.radius * fullWidthPt + 4.0)
                            if hypot(loc.x - sPt.x, loc.y - sPt.y) <= rPt {
                                activeDrag = .source(selected)
                            }
                        }
                        if activeDrag == nil {
                            for spot in spots.reversed() {
                                let tPt = toLocal(spot.targetX, spot.targetY)
                                let rPt = max(12.0, spot.radius * fullWidthPt + 4.0)
                                if hypot(loc.x - tPt.x, loc.y - tPt.y) <= rPt {
                                    appState.selectedSpotHealID = spot.id
                                    activeDrag = .target(spot)
                                    break
                                }
                            }
                        }
                    }

                    if let drag = activeDrag {
                        let (nx, ny) = toNormalized(value.location)
                        switch drag {
                        case .target(var spot):
                            spot.targetX = nx
                            spot.targetY = ny
                            liveDragSpot = spot
                            appState.updateSpotHeal(spot, isDragging: true)
                        case .source(var spot):
                            spot.sourceX = nx
                            spot.sourceY = ny
                            liveDragSpot = spot
                            appState.updateSpotHeal(spot, isDragging: true)
                        }
                    }
                }
                .onEnded { value in
                    if let drag = activeDrag {
                        let (nx, ny) = toNormalized(value.location)
                        switch drag {
                        case .target(var spot):
                            spot.targetX = nx
                            spot.targetY = ny
                            appState.updateSpotHeal(spot, isDragging: false)
                        case .source(var spot):
                            spot.sourceX = nx
                            spot.sourceY = ny
                            appState.updateSpotHeal(spot, isDragging: false)
                        }
                        activeDrag = nil
                        liveDragSpot = nil
                    } else {
                        // Click on empty space -> create a new healed spot!
                        let (nx, ny) = toNormalized(value.location)
                        appState.addSpotHeal(targetX: nx, targetY: ny)
                    }
                }
        )
    }
}

import SwiftUI

/// Sleek floating badge indicating Before (As Shot) or After (Adjusted) state
public struct ComparisonBadge: View {
    public let title: String
    public var subtitle: String? = nil
    public var isBefore: Bool = true
    
    public init(title: String, subtitle: String? = nil, isBefore: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.isBefore = isBefore
    }
    
    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isBefore ? "clock.arrow.circlepath" : "slider.horizontal.3")
                .uiFont(10, weight: .bold)
                .foregroundColor(isBefore ? Color.white : LightroomTheme.accentYellow)
            
            Text(title)
                .uiFont(11, weight: .black)
                .tracking(1.2)
                .foregroundColor(.white)
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .uiFont(9, weight: .medium)
                    .foregroundColor(LightroomTheme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.72))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isBefore ? Color.white.opacity(0.3) : LightroomTheme.accentYellow.opacity(0.5), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 3, x: 0, y: 1)
        .allowsHitTesting(false)
    }
}

/// Interactive draggable divider for Split View (Left/Right or Top/Bottom)
public struct ComparisonSplitDividerView: View {
    public let isVertical: Bool // true for Left/Right, false for Top/Bottom
    public let containerSize: CGSize
    @Binding public var splitPosition: CGFloat // 0.05 to 0.95
    
    @State private var isDragging: Bool = false
    @State private var isHovering: Bool = false
    
    public init(isVertical: Bool = true, containerSize: CGSize, splitPosition: Binding<CGFloat>) {
        self.isVertical = isVertical
        self.containerSize = containerSize
        self._splitPosition = splitPosition
    }
    
    public var body: some View {
        if isVertical {
            // Left / Right Split Divider
            let posX = containerSize.width * max(0.05, min(0.95, splitPosition))
            
            ZStack {
                // Divider Line
                Rectangle()
                    .fill(Color.white.opacity(isDragging || isHovering ? 0.95 : 0.75))
                    .frame(width: 1.5)
                    .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 0)
                
                // Center Drag Handle
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(isDragging || isHovering ? LightroomTheme.accentYellow : Color.white.opacity(0.8), lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .uiFont(11, weight: .bold)
                            .foregroundColor(isDragging || isHovering ? LightroomTheme.accentYellow : Color.white)
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 1)
            }
            .frame(width: 44, height: containerSize.height)
            .contentShape(Rectangle())
            .position(x: posX, y: containerSize.height / 2)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let newPos = value.location.x / max(1, containerSize.width)
                        splitPosition = max(0.05, min(0.95, newPos))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                // Double tap resets to 50% center
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    splitPosition = 0.5
                }
            }
        } else {
            // Top / Bottom Split Divider
            let posY = containerSize.height * max(0.05, min(0.95, splitPosition))
            
            ZStack {
                // Divider Line
                Rectangle()
                    .fill(Color.white.opacity(isDragging || isHovering ? 0.95 : 0.75))
                    .frame(height: 1.5)
                    .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 0)
                
                // Center Drag Handle
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(isDragging || isHovering ? LightroomTheme.accentYellow : Color.white.opacity(0.8), lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "arrow.up.and.down")
                            .uiFont(11, weight: .bold)
                            .foregroundColor(isDragging || isHovering ? LightroomTheme.accentYellow : Color.white)
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 1)
            }
            .frame(width: containerSize.width, height: 44)
            .contentShape(Rectangle())
            .position(x: containerSize.width / 2, y: posY)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let newPos = value.location.y / max(1, containerSize.height)
                        splitPosition = max(0.05, min(0.95, newPos))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                // Double tap resets to 50% center
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    splitPosition = 0.5
                }
            }
        }
    }
}

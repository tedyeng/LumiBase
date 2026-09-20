import SwiftUI

/// Interactive or display 5-star rating view
public struct RatingStarsView: View {
    public let rating: Int
    public var maxRating: Int = 5
    public var starSize: CGFloat = 12
    public var isInteractive: Bool = false
    public var onRatingChanged: ((Int) -> Void)?
    
    public init(
        rating: Int,
        maxRating: Int = 5,
        starSize: CGFloat = 12,
        isInteractive: Bool = false,
        onRatingChanged: ((Int) -> Void)? = nil
    ) {
        self.rating = rating
        self.maxRating = maxRating
        self.starSize = starSize
        self.isInteractive = isInteractive
        self.onRatingChanged = onRatingChanged
    }
    
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxRating, id: \.self) { starIndex in
                Image(systemName: starIndex <= rating ? "star.fill" : "star")
                    .font(.system(size: starSize))
                    .foregroundColor(starIndex <= rating ? LightroomTheme.accentYellow : LightroomTheme.textMuted.opacity(0.5))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isInteractive {
                            if rating == starIndex {
                                onRatingChanged?(0) // Toggle off
                            } else {
                                onRatingChanged?(starIndex)
                            }
                        }
                    }
            }
        }
    }
}

/// Color label dot or badge
public struct ColorBadgeView: View {
    public let label: ColorLabel
    public var size: CGFloat = 10
    public var isInteractive: Bool = false
    public var onSelect: ((ColorLabel) -> Void)?
    
    public init(label: ColorLabel, size: CGFloat = 10, isInteractive: Bool = false, onSelect: ((ColorLabel) -> Void)? = nil) {
        self.label = label
        self.size = size
        self.isInteractive = isInteractive
        self.onSelect = onSelect
    }
    
    public var body: some View {
        if label != .none {
            Circle()
                .fill(LightroomTheme.color(for: label))
                .frame(width: size, height: size)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

/// Pick / Reject flag badge
public struct FlagBadgeView: View {
    public let flag: FlagStatus
    public var size: CGFloat = 12
    public var isInteractive: Bool = false
    public var onToggle: (() -> Void)?
    
    public init(flag: FlagStatus, size: CGFloat = 12, isInteractive: Bool = false, onToggle: (() -> Void)? = nil) {
        self.flag = flag
        self.size = size
        self.isInteractive = isInteractive
        self.onToggle = onToggle
    }
    
    public var body: some View {
        Group {
            switch flag {
            case .pick:
                Image(systemName: "flag.fill")
                    .foregroundColor(Color.white)
            case .reject:
                Image(systemName: "xmark")
                    .foregroundColor(Color.red)
                    .fontWeight(.bold)
            case .unflagged:
                if isInteractive {
                    Image(systemName: "flag")
                        .foregroundColor(LightroomTheme.textMuted.opacity(0.4))
                } else {
                    EmptyView()
                }
            }
        }
        .font(.system(size: size))
        .onTapGesture {
            if isInteractive {
                onToggle?()
            }
        }
    }
}

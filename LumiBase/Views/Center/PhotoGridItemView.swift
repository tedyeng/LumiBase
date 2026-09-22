import SwiftUI
import AppKit

/// Individual cell item in the Lightroom Library Grid
public struct PhotoGridItemView: View {
    public let asset: PhotoAsset
    public let isSelected: Bool
    public let isPrimary: Bool
    public let size: CGFloat
    public let onSelect: (_ isToggle: Bool, _ isRange: Bool) -> Void
    public let onDoubleClick: () -> Void
    public let onRatingChange: (Int) -> Void
    public let onFlagToggle: () -> Void
    
    @State private var thumbnail: NSImage?
    @State private var isLoading: Bool = true
    
    public var body: some View {
        VStack(spacing: 0) {
            // Image Preview Container
            ZStack(alignment: .topLeading) {
                // Image or Placeholder
                ZStack {
                    Color.black.opacity(0.3)
                    
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                .frame(width: size, height: size * 0.75)
                .clipped()
                
                // Top-Left: RAW, RAW+JPG, XMP & Flag Badges
                HStack(spacing: 4) {
                    if asset.isRawPlusJPG {
                        Text("RAW+JPG")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.85))
                            .cornerRadius(2)
                            .help("Paired RAW + JPEG photo")
                    } else if asset.isRaw {
                        Text(asset.fileExtension.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(2)
                    }
                    
                    if asset.xmp.isLoadedFromSidecar {
                        HStack(spacing: 2) {
                            Text("XMP")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                            if asset.xmp.hasDevelopEdits {
                                Text("±")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(LightroomTheme.accentYellow)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.85))
                        .cornerRadius(2)
                        .help("XMP Sidecar Loaded" + (asset.xmp.hasDevelopEdits ? " (with Camera Raw Adjustments)" : ""))
                    }
                    
                    FlagBadgeView(flag: asset.xmp.flag, size: 10, isInteractive: true) {
                        onFlagToggle()
                    }
                }
                .padding(5)
            }
            
            // Cell Footer (Rating Stars & Filename)
            HStack(spacing: 4) {
                // Interactive Star Rating
                RatingStarsView(
                    rating: asset.xmp.rating,
                    starSize: 9,
                    isInteractive: true,
                    onRatingChanged: onRatingChange
                )
                
                Spacer()
                
                // Filename
                Text(asset.filename)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? LightroomTheme.textPrimary : LightroomTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? LightroomTheme.cardSelectedBackground : LightroomTheme.cardBackground)
        }
        .frame(width: size)
        .background(LightroomTheme.cardBackground)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isPrimary ? LightroomTheme.accentYellow :
                    (isSelected ? Color.white.opacity(0.8) : LightroomTheme.cardBorder),
                    lineWidth: isPrimary ? 2 : (isSelected ? 1.5 : 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            let isToggle = flags.contains(.control) || flags.contains(.command)
            let isRange = flags.contains(.shift)
            onSelect(isToggle, isRange)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick()
            }
        )
        .task(id: asset.id) {
            await loadThumbnail()
        }
    }
    
    @MainActor
    private func loadThumbnail() async {
        isLoading = true
        let loaded = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: Int(size * 2))
        self.thumbnail = loaded
        self.isLoading = false
    }
}

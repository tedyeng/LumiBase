import SwiftUI

/// Lightroom-style top filter bar for searching, rating filter, flag filter, and color labels
public struct TopFilterBarView: View {
    @ObservedObject var appState: AppState
    @FocusState private var isSearchFocused: Bool
    
    public var body: some View {
        HStack(spacing: 16) {
            // Search Input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(isSearchFocused ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                    .font(.system(size: 11))
                
                TextField("Search (Filename, Camera, Keyword...)", text: $appState.filterCriteria.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(LightroomTheme.textPrimary)
                    .focused($isSearchFocused)
                    .onSubmit {
                        isSearchFocused = false
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
                    .onExitCommand {
                        isSearchFocused = false
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
                
                if !appState.filterCriteria.searchText.isEmpty {
                    Button {
                        appState.filterCriteria.searchText = ""
                        isSearchFocused = false
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(LightroomTheme.textMuted)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(LightroomTheme.cardBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSearchFocused ? LightroomTheme.accentYellow.opacity(0.8) : LightroomTheme.cardBorder, lineWidth: 1)
            )
            .frame(width: 250)
            .onAppear {
                isSearchFocused = false
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LumiBaseFocusSearch"))) { _ in
                isSearchFocused = true
            }
            
            Divider()
                .frame(height: 14)
                .background(LightroomTheme.dividerColor)
            
            // Rating Filter Buttons (>= 1 to 5)
            HStack(spacing: 4) {
                Text("Rating:")
                    .font(.system(size: 11))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                ForEach(1...5, id: \.self) { star in
                    Button {
                        if appState.filterCriteria.minimumRating == star {
                            appState.filterCriteria.minimumRating = 0
                        } else {
                            appState.filterCriteria.minimumRating = star
                            appState.filterCriteria.ratingExact = false
                        }
                    } label: {
                        Image(systemName: star <= appState.filterCriteria.minimumRating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(star <= appState.filterCriteria.minimumRating ? LightroomTheme.accentYellow : LightroomTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                
                if appState.filterCriteria.minimumRating > 0 {
                    Text("≥ \(appState.filterCriteria.minimumRating)★")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(LightroomTheme.accentYellow)
                }
            }
            
            Divider()
                .frame(height: 14)
                .background(LightroomTheme.dividerColor)
            
            // Flag Filters (Pick, Reject, Unflagged)
            HStack(spacing: 8) {
                Text("Flag:")
                    .font(.system(size: 11))
                    .foregroundColor(LightroomTheme.textSecondary)
                
                flagFilterButton(flag: .pick, icon: "flag.fill", color: .white)
                flagFilterButton(flag: .reject, icon: "xmark", color: .red)
                flagFilterButton(flag: .unflagged, icon: "circle.dashed", color: LightroomTheme.textMuted)
            }
            
            Spacer()
            
            // Reset Filters Button
            if appState.filterCriteria.isActive {
                Button {
                    appState.filterCriteria.reset()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Filter")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(LightroomTheme.accentYellow)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(LightroomTheme.headerBackground)
    }
    
    private func flagFilterButton(flag: FlagStatus, icon: String, color: Color) -> some View {
        let isSelected = appState.filterCriteria.selectedFlag == flag
        return Button {
            if isSelected {
                appState.filterCriteria.selectedFlag = nil
            } else {
                appState.filterCriteria.selectedFlag = flag
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isSelected ? color : LightroomTheme.textMuted.opacity(0.4))
                .padding(3)
                .background(isSelected ? LightroomTheme.cardSelectedBackground : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

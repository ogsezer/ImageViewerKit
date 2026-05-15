// DisplayModeToggleView.swift
// ImageViewerKit
//
// Floating capsule control showing the current SDR/HDR/Auto state plus
// the headroom of the current image (e.g. "HDR 2.4×" for an iPhone HDR photo)
// and an optional COMPARE indicator when split-view is active.

import SwiftUI

@MainActor
struct DisplayModeToggleView: View {

    let mode: ImageViewerConfiguration.DisplayMode
    let displaySupportsHDR: Bool
    let imageHeadroom: Float
    let isComparing: Bool
    let onTap: () -> Void

    private var hasHDRContent: Bool { imageHeadroom > 1.001 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11, weight: .semibold))

                Text(mode.displayName)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.5)

                // Effective HDR + headroom badge
                if mode != .sdr && hasHDRContent && (displaySupportsHDR || mode == .hdr) {
                    headroomBadge
                }

                // Auto resolved to HDR but image is SDR
                if mode == .auto && displaySupportsHDR && !hasHDRContent {
                    miniBadge(text: "no HDR data", color: .white.opacity(0.55))
                }

                // Forcing HDR on a non-HDR display
                if mode == .hdr && !displaySupportsHDR {
                    miniBadge(text: "UNSUPPORTED", color: .orange)
                }

                // Compare mode active
                if isComparing {
                    Divider()
                        .frame(height: 12)
                        .background(Color.white.opacity(0.25))
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                    Text("COMPARE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var headroomBadge: some View {
        Text(String(format: "%.1f×", imageHeadroom))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .leading, endPoint: .trailing))
            )
    }

    private func miniBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.10)))
    }

    private var helpText: String {
        var lines: [String] = []
        switch mode {
        case .sdr:  lines.append("Standard dynamic range")
        case .hdr:  lines.append("Forcing HDR (EDR) on this display")
        case .auto: lines.append("Auto: HDR if supported, SDR otherwise")
        }
        if hasHDRContent {
            lines.append(String(format: "Image headroom: %.2f× SDR white", imageHeadroom))
        } else {
            lines.append("Image is SDR (no HDR pixel data)")
        }
        lines.append("Click to cycle (or press H)")
        lines.append("Press C to compare SDR | HDR")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        DisplayModeToggleView(mode: .auto, displaySupportsHDR: true,
                              imageHeadroom: 2.4, isComparing: false, onTap: {})
        DisplayModeToggleView(mode: .hdr, displaySupportsHDR: true,
                              imageHeadroom: 4.0, isComparing: false, onTap: {})
        DisplayModeToggleView(mode: .auto, displaySupportsHDR: true,
                              imageHeadroom: 1.0, isComparing: false, onTap: {})
        DisplayModeToggleView(mode: .hdr, displaySupportsHDR: false,
                              imageHeadroom: 2.0, isComparing: false, onTap: {})
        DisplayModeToggleView(mode: .sdr, displaySupportsHDR: true,
                              imageHeadroom: 2.4, isComparing: true, onTap: {})
    }
    .padding(40)
    .background(Color.black)
}

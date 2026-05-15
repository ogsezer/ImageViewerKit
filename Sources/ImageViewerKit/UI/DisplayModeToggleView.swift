// DisplayModeToggleView.swift
// ImageViewerKit
//
// A small floating capsule control that shows the current SDR/HDR/Auto state
// and lets the user cycle through modes by clicking it.

import SwiftUI

@MainActor
struct DisplayModeToggleView: View {

    let mode: ImageViewerConfiguration.DisplayMode
    let displaySupportsHDR: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.displayName)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.5)

                // "Auto → HDR active" or "HDR forced" hints
                if mode == .auto && displaySupportsHDR {
                    Text("HDR")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.white.opacity(0.15))
                        )
                }
                if mode == .hdr && !displaySupportsHDR {
                    Text("UNSUPPORTED")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
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

    private var helpText: String {
        switch mode {
        case .sdr:  return "Standard dynamic range — click to cycle (or press H)"
        case .hdr:  return "Forcing HDR (EDR) on this display — click to cycle"
        case .auto: return "Auto: HDR if supported, SDR otherwise — click to cycle"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        DisplayModeToggleView(mode: .auto, displaySupportsHDR: true,  onTap: {})
        DisplayModeToggleView(mode: .hdr,  displaySupportsHDR: true,  onTap: {})
        DisplayModeToggleView(mode: .sdr,  displaySupportsHDR: false, onTap: {})
        DisplayModeToggleView(mode: .hdr,  displaySupportsHDR: false, onTap: {})
    }
    .padding(40)
    .background(Color.black)
}

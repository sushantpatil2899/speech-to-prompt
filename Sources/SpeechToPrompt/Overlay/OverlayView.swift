import DictateCore
import SwiftUI

/// The small card in the top-right corner.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    static let cardSize = CGSize(width: 248, height: 56)

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 12)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(10)  // room for the shadow inside the panel
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()

        case .listening(let mode):
            ModeBadge(mode: mode, active: true)
            Waveform(levels: model.levels)

        case .processing(let mode):
            SpinnerRing()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode == .raw ? "Transcribing…" : "Working…")
                    .font(.system(size: 13, weight: .semibold))
                Text(mode == .raw ? "Raw" : "Clean")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

        case .done(_, let text, let detail):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail ?? "Pasted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .message(let text, let isError):
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "waveform.slash")
                .font(.system(size: 18))
                .foregroundStyle(isError ? Color.orange : Color.secondary)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Circle with the mode's icon. Raw = text cursor, Clean = wand.
private struct ModeBadge: View {
    let mode: DictationMode
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(mode == .raw ? Color.blue.gradient : Color.purple.gradient)
            Image(systemName: mode == .raw ? "text.cursor" : "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .help(mode == .raw ? "Raw dictation" : "Clean dictation")
    }
}

/// Bars driven by the live microphone level (newest on the right).
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .bottom, endPoint: .top))
                    .frame(width: 4, height: max(4, CGFloat(level) * 34))
            }
        }
        .frame(height: 36)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// A ring with a colour gradient that rotates while work is in progress.
struct SpinnerRing: View {
    var body: some View {
        TimelineView(.animation) { context in
            let period = 1.1
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [.blue, .purple, .pink, .orange, .yellow, .blue],
                        center: .center),
                    lineWidth: 4)
                .rotationEffect(.degrees(t * 360))
        }
    }
}

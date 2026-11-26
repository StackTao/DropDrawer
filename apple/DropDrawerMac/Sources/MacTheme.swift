import AppKit
import SwiftUI

/// Restrained dark-frosted macOS palette and native components mirroring the
/// DropDrawer desktop visual language over `NSVisualEffectView (.hudWindow + .darkAqua)`.
public enum MacTheme {
    public static let surfaceTint = Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.72)
    public static let cardBg = Color.white.opacity(0.065)
    public static let cardHoverBg = Color.white.opacity(0.115)
    public static let elevatedBg = Color(red: 30 / 255, green: 30 / 255, blue: 32 / 255)
    public static let hairline = Color.white.opacity(0.11)
    public static let strongHairline = Color.white.opacity(0.19)

    public static let textPrimary = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    public static let textSecondary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.60)
    public static let textTertiary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.36)
    public static let onTextPrimary = Color(red: 17 / 255, green: 17 / 255, blue: 19 / 255)

    public static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    public static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    public static let amber = Color(red: 255 / 255, green: 214 / 255, blue: 10 / 255)
    public static let red = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

    public static func fill(_ alpha: Double) -> Color {
        Color.white.opacity(alpha)
    }

    public static func group(_ alpha: Double = 0.22) -> Color {
        Color.black.opacity(alpha)
    }

    public static func shade(_ alpha: Double = 0.28) -> Color {
        Color.black.opacity(alpha)
    }
}

// MARK: - Hairline Divider

struct MacDivider: View {
    var indent: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(MacTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, indent)
    }
}

// MARK: - Ghost Toolbar / Action Icon Button (transparent at rest, subtle plate on hover)

struct MacIconButton: View {
    let symbol: String
    var active: Bool = false
    var tint: Color? = nil
    var size: CGFloat = 13.5
    var boxSize: CGFloat = 26
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .light))
                .foregroundStyle(foregroundColor)
                .frame(width: boxSize, height: boxSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foregroundColor: Color {
        if let tint { return tint }
        if active || isHovered { return MacTheme.textPrimary }
        return MacTheme.textSecondary
    }

    private var backgroundColor: Color {
        if active { return MacTheme.fill(0.16) }
        if isHovered { return MacTheme.fill(0.10) }
        return .clear
    }
}

// MARK: - Control-Center Pill Segmented Control

struct MacSegmentedControl<T: Hashable>: View {
    let items: [(T, String)]
    let selected: T
    let onChanged: (T) -> Void

    @Namespace private var thumbNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                let isSelected = entry.0 == selected
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        onChanged(entry.0)
                    }
                } label: {
                    Text(entry.1)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? MacTheme.textPrimary : MacTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(MacTheme.fill(0.16))
                                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "seg_thumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 26)
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(MacTheme.shade(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(MacTheme.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - Signature Inverted White Primary Button & Subtle Dark Secondary Button

struct MacPrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var loading: Bool = false
    var disabled: Bool = false
    var height: CGFloat = 36
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.light)
                } else {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13.5, weight: .medium))
                    }
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                }
            }
            .foregroundStyle(MacTheme.onTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(disabled ? MacTheme.fill(0.25) : MacTheme.textPrimary.opacity(isHovered ? 0.90 : 1.0))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
        .onHover { isHovered = $0 }
    }
}

/// Natural left-to-right wrapping layout (mirrors Flutter `Wrap`).
struct MacFlowLayout: Layout {
    var spacing: CGFloat = 6
    var runSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, usedWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct MacSecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var destructive: Bool = false
    var height: CGFloat = 32
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(destructive ? MacTheme.red : MacTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(destructive
                          ? MacTheme.red.opacity(isHovered ? 0.18 : 0.11)
                          : MacTheme.fill(isHovered ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(destructive ? MacTheme.red.opacity(0.28) : MacTheme.hairline, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recessed Grouped Card & Form Row

struct MacGroupedCard<Content: View>: View {
    var alpha: Double = 0.22
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MacTheme.group(alpha))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MacTheme.hairline, lineWidth: 0.7)
        )
    }
}

struct MacFormRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var labelWidth: CGFloat = 56
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(MacTheme.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(MacTheme.textTertiary))
                        .onSubmit { onSubmit?() }
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(MacTheme.textTertiary))
                        .onSubmit { onSubmit?() }
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(MacTheme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Subpage Header (matches Flutter macOS desktop header)

struct MacSubpageHeader: View {
    let title: String
    @Bindable var controller: EdgeDrawerController
    var trailing: AnyView? = nil

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 4) {
            MacIconButton(symbol: "chevron.left", size: 13.5, help: "返回抽屉") {
                controller.route = .home
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { _ in
                            guard controller.isEdgeMode else { return }
                            if !isDragging {
                                isDragging = true
                                controller.beginHeaderDrag()
                            }
                            controller.updateHeaderDrag()
                        }
                        .onEnded { _ in
                            isDragging = false
                            controller.endHeaderDrag()
                        }
                )
            if let trailing {
                trailing
            }
        }
        .frame(height: 26)
        .padding(.leading, controller.isEdgeMode ? 10 : 78)
        .padding(.trailing, 10)
        .padding(.top, controller.isEdgeMode ? 10 : 5)
        .padding(.bottom, controller.isEdgeMode ? 9 : 6)
    }
}

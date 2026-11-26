import DropDrawerCore
import SwiftUI

/// Server-wide announcement from the admin console, shown at the top of the
/// home list. Closing it hides this revision until the administrator edits it.
struct AnnouncementSection: View {
    let announcement: ClientAnnouncement
    let onDismiss: () -> Void

    private var tint: Color {
        switch announcement.level {
        case "critical": .red
        case "warning": .orange
        default: .accentColor
        }
    }

    private var symbol: String {
        switch announcement.level {
        case "critical": "exclamationmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "megaphone.fill"
        }
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if !announcement.title.isEmpty {
                        Text(announcement.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    if !announcement.message.isEmpty {
                        Text(announcement.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭公告")
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
        .listRowBackground(tint.opacity(0.12))
    }
}

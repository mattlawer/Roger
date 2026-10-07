import SwiftUI

/// A fully-tappable disclosure header: a rotating chevron plus a custom label, with a hover
/// highlight. The entire row is the hit target (not just the glyphs), which fixes chevrons
/// that only toggle when the pointer lands exactly on the icon.
struct DisclosureRow<Label: View>: View {
    let isExpanded: Bool
    var trailing: String? = nil
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                label()
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

import SwiftUI

struct PhotoCardView: View {
    let item: PhotoGridItem
    var isHighlighted: Bool = false
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Square cell + scaledToFit (in PreviewImage) shows the whole frame; a 3:4
            // fill cell cropped landscape photos.
            PreviewImage(previewPath: item.previewPath)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.orange, lineWidth: isHighlighted ? 3 : 0)
                )

            Text(item.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if let score = item.overallScore {
                    Text(String(format: "%.0f", score)).font(.headline)
                }
                if let rec = item.recommendation {
                    RecommendationBadge(recommendation: rec)
                }
            }

            if let role = item.groupRole {
                Text(role.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .foregroundStyle(role == "strongest" ? .green : (role == "weakest" ? .red : .secondary))
            }

            HStack(spacing: 6) {
                if let lookName = item.lookName {
                    Text(lookName)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                if let personName = item.personName {
                    Text(personName)
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.blue, lineWidth: isSelected ? 3 : 0)
        )
        .contentShape(Rectangle())
    }
}

struct RecommendationBadge: View {
    let recommendation: String

    private var color: Color {
        switch recommendation {
        case "KEEP": .green
        case "MAYBE": .yellow
        case "REJECT": .red
        default: .secondary
        }
    }

    var body: some View {
        Text(recommendation)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
}

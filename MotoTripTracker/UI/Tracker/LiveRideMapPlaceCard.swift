import CoreLocation
import SwiftUI

struct PickedMapPlace: Equatable, Identifiable {
    let name: String
    let category: String?
    let address: String
    let phone: String?
    let websiteHost: String?
    let websiteURL: URL?
    let latitude: Double
    let longitude: Double

    var id: String { "\(latitude),\(longitude),\(name)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var categorySymbol: String {
        let key = (category ?? "").lowercased()
        if key.contains("restaurant") || key.contains("cafe") || key.contains("food") {
            return "fork.knife.circle.fill"
        }
        if key.contains("hotel") || key.contains("lodging") {
            return "bed.double.circle.fill"
        }
        if key.contains("gas") || key.contains("fuel") {
            return "fuelpump.circle.fill"
        }
        if key.contains("store") || key.contains("shop") || key.contains("market") {
            return "bag.circle.fill"
        }
        if key.contains("park") || key.contains("museum") || key.contains("theater") {
            return "star.circle.fill"
        }
        return "mappin.circle.fill"
    }

    init(
        name: String,
        category: String?,
        address: String,
        phone: String?,
        websiteHost: String?,
        websiteURL: URL?,
        coordinate: CLLocationCoordinate2D
    ) {
        self.name = name
        self.category = category
        self.address = address
        self.phone = phone
        self.websiteHost = websiteHost
        self.websiteURL = websiteURL
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

struct LiveRideMapPlaceCard: View {
    let place: PickedMapPlace
    let colors: AppPalette
    let isResolving: Bool
    let onDismiss: () -> Void
    let onGo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: place.categorySymbol)
                    .font(.title)
                    .foregroundStyle(colors.neonBlue)
                    .frame(width: 36, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let category = place.category, !category.isEmpty {
                        Text(category)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colors.neonBlue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(colors.neonBlue.opacity(0.14), in: Capsule())
                    }
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(colors.textSecondary)
                }
                .accessibilityLabel("Dismiss place")
            }

            if !place.address.isEmpty {
                labelRow(
                    systemImage: "building.2.fill",
                    text: place.address,
                    colors: colors,
                    lineLimit: 4
                )
            }

            if let phone = place.phone, !phone.isEmpty, let phoneURL = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                Link(destination: phoneURL) {
                    labelRow(systemImage: "phone.fill", text: phone, colors: colors, lineLimit: 1)
                }
                .buttonStyle(.plain)
            }

            if let website = place.websiteHost, !website.isEmpty, let url = place.websiteURL {
                Link(destination: url) {
                    labelRow(systemImage: "globe", text: website, colors: colors, lineLimit: 1)
                }
                .buttonStyle(.plain)
            }

            if isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading place details…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.textSecondary)
                }
            }

            Button(action: onGo) {
                Text("Go")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(colors.bgDeep)
                    .background(colors.neonGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isResolving)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func labelRow(
        systemImage: String,
        text: String,
        colors: AppPalette,
        lineLimit: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.textSecondary)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

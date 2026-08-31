import SwiftUI

/// date-only birth date strings from the people api, utc "yyyy-MM-dd".
nonisolated enum PersonBirthDate {
    private static let wire: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        wire.date(from: String(raw.prefix(10)))
    }

    static func string(from date: Date) -> String {
        wire.string(from: date)
    }

    /// localized "Jan 5, 1990", anchored to utc so the day never drifts.
    static func displayLabel(_ raw: String) -> String? {
        guard let date = parse(raw) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }

    /// age today, phrased like the reference clients: months under one year,
    /// year and months under two, plain years after.
    static func ageLabel(_ raw: String, at reference: Date = .now) -> String? {
        guard let birth = parse(raw) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let months = calendar.dateComponents([.month], from: birth, to: reference).month ?? 0
        guard months >= 0 else { return nil }
        if months <= 11 { return "\(months) months old" }
        if months < 24 { return "1 year, \(months - 12) months old" }
        return "Age \(months / 12)"
    }
}

/// circular person thumbnail that fills its container square. favorites wear
/// a small glass heart riding the circle's edge.
struct PersonAvatar: View {
    @Environment(SessionStore.self) private var session
    let person: Person
    var targetPixelSize: CGFloat = 240
    var showsFavorite = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = session.personThumbnailURL(person) {
                    RemoteImage(url: url, targetPixelSize: targetPixelSize)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(.circle)
            .overlay(alignment: .bottomTrailing) {
                if showsFavorite, person.isFavorite == true {
                    Image(systemName: "heart.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.pink)
                        .padding(4)
                        .glassEffect(.regular, in: .circle)
                        .accessibilityHidden(true)
                }
            }
    }
}

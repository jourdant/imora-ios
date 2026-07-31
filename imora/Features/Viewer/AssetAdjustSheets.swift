import SwiftUI
import MapKit

// MARK: - date and time

/// photos-style adjust sheet: wall-clock picker plus time zone, saved as an
/// offset-suffixed timestamp the way the official clients do.
struct AdjustDateTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let detail: AssetDetail
    let onSaved: (Date, Double) -> Void

    /// wall clock held in utc components, matching how asset dates render.
    @State private var wallClock: Date
    @State private var zoneID: String
    @State private var isSaving = false
    @State private var error: String?

    private static let utc = TimeZone(identifier: "UTC")!

    init(asset: Asset, detail: AssetDetail, onSaved: @escaping (Date, Double) -> Void) {
        self.asset = asset
        self.detail = detail
        self.onSaved = onSaved
        _wallClock = State(initialValue: asset.localDate)
        _zoneID = State(initialValue: Self.initialZone(detail: detail, offsetHours: asset.localOffsetHours))
    }

    /// prefer the exif zone name; else any zone matching the asset's offset;
    /// else the device zone.
    private static func initialZone(detail: AssetDetail, offsetHours: Double) -> String {
        if let raw = detail.exifInfo?.timeZone {
            if TimeZone(identifier: raw) != nil { return raw }
            if raw.uppercased().hasPrefix("UTC"),
               let zone = TimeZone(identifier: "GMT" + raw.dropFirst(3)) {
                return zone.identifier
            }
        }
        let offsetSeconds = Int((offsetHours * 3600).rounded())
        if TimeZone.current.secondsFromGMT() == offsetSeconds {
            return TimeZone.current.identifier
        }
        if let match = TimeZone.knownTimeZoneIdentifiers.first(where: {
            TimeZone(identifier: $0)?.secondsFromGMT() == offsetSeconds
        }) {
            return match
        }
        return TimeZone.current.identifier
    }

    private var zone: TimeZone { TimeZone(identifier: zoneID) ?? Self.utc }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Date",
                        selection: $wallClock,
                        in: Date.distantPast...Date.now.addingTimeInterval(14 * 3600),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    // the picker edits the stored utc components directly, so
                    // they stay pure wall-clock values.
                    .environment(\.timeZone, Self.utc)
                }

                Section {
                    NavigationLink {
                        TimeZonePicker(selection: $zoneID, reference: wallClock)
                    } label: {
                        HStack {
                            Text("Time Zone")
                            Spacer()
                            Text(zoneLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Adjust Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                        .accessibilityIdentifier("adjust-date-save")
                }
            }
            .alert(error ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var zoneLabel: String {
        let name = zoneID.replacingOccurrences(of: "_", with: " ")
        return "\(name) (GMT\(AssetInfoSheet.offsetLabel(hours: Double(offsetSeconds) / 3600)))"
    }

    /// zone offset for the picked wall clock, resolved against the real
    /// instant so daylight saving is honored.
    private var offsetSeconds: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wallClock)
        components.timeZone = zone
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = zone
        let instant = zoned.date(from: components) ?? wallClock
        return zone.secondsFromGMT(for: instant)
    }

    private func save() async {
        guard let client = session.client else { return }
        isSaving = true
        defer { isSaving = false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = Self.utc
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let offset = offsetSeconds
        let iso = formatter.string(from: wallClock) + AssetInfoSheet.offsetLabel(hours: Double(offset) / 3600)

        do {
            try await client.updateAsset(id: asset.id, dateTimeOriginal: iso)
            let instant = wallClock.addingTimeInterval(TimeInterval(-offset))
            onSaved(instant, Double(offset) / 3600)
            dismiss()
        } catch {
            self.error = "Could not adjust the date: \(error.localizedDescription)"
        }
    }
}

/// searchable list of iana time zones, sorted by offset.
private struct TimeZonePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let reference: Date

    @State private var query = ""

    private var zones: [(id: String, offset: Int)] {
        let all = TimeZone.knownTimeZoneIdentifiers.compactMap { id -> (String, Int)? in
            guard let zone = TimeZone(identifier: id) else { return nil }
            return (id, zone.secondsFromGMT(for: reference))
        }
        let filtered = query.isEmpty
            ? all
            : all.filter { $0.0.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: "_")) }
        return filtered.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }
    }

    var body: some View {
        List(zones, id: \.id) { zone in
            Button {
                selection = zone.id
                dismiss()
            } label: {
                HStack {
                    Text(zone.id.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("GMT\(AssetInfoSheet.offsetLabel(hours: Double(zone.offset) / 3600))")
                        .foregroundStyle(.secondary)
                    if zone.id == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search time zones")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - location

/// pick a place by searching or tapping the map, photos style.
struct AdjustLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let detail: AssetDetail
    let onSaved: () -> Void

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition
    @State private var search = LocationSearchModel()
    @State private var query = ""
    @State private var isSaving = false
    @State private var error: String?

    init(asset: Asset, detail: AssetDetail, onSaved: @escaping () -> Void) {
        self.asset = asset
        self.detail = detail
        self.onSaved = onSaved
        if let latitude = detail.exifInfo?.latitude,
           let longitude = detail.exifInfo?.longitude,
           latitude != 0 || longitude != 0 {
            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            _coordinate = State(initialValue: center)
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )))
        } else {
            _coordinate = State(initialValue: nil)
            _camera = State(initialValue: .automatic)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(position: $camera) {
                        if let coordinate {
                            Marker("", coordinate: coordinate)
                        }
                    }
                    .onTapGesture { position in
                        guard let tapped = proxy.convert(position, from: .local) else { return }
                        coordinate = tapped
                        search.results = []
                    }
                }
                .ignoresSafeArea(.keyboard)

                VStack(spacing: 0) {
                    TextField("Search for a place", text: $query)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .onChange(of: query) { _, text in
                            search.update(query: text)
                        }
                        .accessibilityIdentifier("adjust-location-search")

                    if !search.results.isEmpty {
                        List(search.results, id: \.self) { completion in
                            Button {
                                Task { await select(completion) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(completion.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if !completion.subtitle.isEmpty {
                                        Text(completion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .frame(maxHeight: 240)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let coordinate {
                    Text("\(coordinate.latitude.formatted(.number.precision(.fractionLength(4)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(4))))")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.bottom, 10)
                }
            }
            .navigationTitle("Adjust Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || coordinate == nil)
                        .accessibilityIdentifier("adjust-location-save")
                }
            }
            .alert(error ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) async {
        guard let found = await search.resolve(completion) else { return }
        coordinate = found
        camera = .region(MKCoordinateRegion(
            center: found,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
        query = completion.title
        search.results = []
    }

    private func save() async {
        guard let client = session.client, let coordinate else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.updateAsset(
                id: asset.id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            onSaved()
            dismiss()
        } catch {
            self.error = "Could not save the location: \(error.localizedDescription)"
        }
    }
}

/// thin observable wrapper around mapkit's search completer.
@MainActor
@Observable
final class LocationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []

    @ObservationIgnored private lazy var completer: MKLocalSearchCompleter = {
        let completer = MKLocalSearchCompleter()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        return completer
    }()

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            completer.cancel()
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        let response = try? await search.start()
        return response?.mapItems.first?.placemark.coordinate
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = completer.results
        Task { @MainActor in
            results = Array(found.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            results = []
        }
    }
}

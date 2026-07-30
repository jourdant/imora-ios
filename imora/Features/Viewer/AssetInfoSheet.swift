import SwiftUI
import MapKit

struct AssetInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset

    private enum LoadState {
        case loading
        case loaded(AssetDetail)
        case failed(String)
    }

    @State private var loadState = LoadState.loading

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    dateHeader

                    switch loadState {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 80)
                    case .failed(let message):
                        ContentUnavailableView {
                            Label("Couldn't Load Info", systemImage: "exclamationmark.circle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try Again") { Task { await load() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    case .loaded(let detail):
                        detailContent(detail)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("asset-details")
        .task(id: asset.id) { await load() }
    }

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(asset.localDate, format: .dateTime.weekday(.wide).month(.wide).day().year().utc())
                .font(.title3.weight(.semibold))
            HStack(spacing: 5) {
                Text(asset.localDate, format: .dateTime.hour().minute().utc())
                if let location = [asset.city, asset.country]
                    .compactMap({ $0 })
                    .first(where: { !$0.isEmpty }) {
                    Text("•")
                    Text(location)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func detailContent(_ detail: AssetDetail) -> some View {
        if let description = detail.exifInfo?.description, !description.isEmpty {
            infoSection("Caption") {
                Text(description)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        infoSection("Details") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: fileIcon(for: detail.type))
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: .circle)

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.originalFileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)

                    if let summary = fileSummary(detail) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if let exif = detail.exifInfo {
            let camera = cameraName(exif)
            let lens = exif.lensModel?.isEmpty == false ? exif.lensModel : nil
            let specifications = cameraSpecifications(exif)

            if camera != nil || lens != nil || !specifications.isEmpty {
                infoSection("Camera") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let camera {
                            Label(camera, systemImage: "camera")
                                .font(.subheadline.weight(.semibold))
                        }

                        if let lens {
                            Text(lens)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !specifications.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    specificationChips(specifications)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    specificationChips(specifications)
                                }
                            }
                        }
                    }
                }
            }
        }

        if let exif = detail.exifInfo,
           let latitude = exif.latitude,
           let longitude = exif.longitude {
            locationSection(exif, latitude: latitude, longitude: longitude)
        }

        if let people = detail.people, !people.isEmpty {
            peopleSection(people)
        }
    }

    private func infoSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))
        }
    }

    private func locationSection(
        _ exif: ExifInfo,
        latitude: Double,
        longitude: Double
    ) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let place = [exif.city, exif.state, exif.country]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 10) {
            Text("Location")
                .font(.headline)

            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))) {
                Marker("", coordinate: coordinate)
            }
            .frame(height: 180)
            .clipShape(.rect(cornerRadius: 16))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                if !place.isEmpty {
                    Text(place)
                        .font(.subheadline.weight(.medium))
                }
                Text("\(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func peopleSection(_ people: [Person]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(people) { person in
                        VStack(spacing: 6) {
                            if let client = session.client {
                                RemoteImage(
                                    url: client.personThumbnailURL(personID: person.id),
                                    targetPixelSize: 160
                                )
                                .frame(width: 64, height: 64)
                                .clipShape(.circle)
                            }
                            Text(person.name.isEmpty ? "Unnamed" : person.name)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 72)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func specificationChips(_ specifications: [String]) -> some View {
        ForEach(Array(specifications.enumerated()), id: \.offset) { _, specification in
            Text(specification)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.tertiary.opacity(0.65), in: .capsule)
        }
    }

    private func fileIcon(for type: AssetType) -> String {
        switch type {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .other: "doc"
        }
    }

    private func fileSummary(_ detail: AssetDetail) -> String? {
        var parts: [String] = []

        if let mime = detail.originalMimeType?.split(separator: "/").last {
            parts.append(mime.uppercased())
        }
        if let dimensions = dimensions(detail) {
            parts.append(dimensions)
        }
        if let bytes = detail.exifInfo?.fileSizeInByte {
            parts.append(ByteCountFormatStyle().format(bytes))
        }
        if let duration = asset.durationLabel {
            parts.append(duration)
        }

        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }

    private func dimensions(_ detail: AssetDetail) -> String? {
        let width = detail.width ?? detail.exifInfo?.exifImageWidth.map { Int($0) }
        let height = detail.height ?? detail.exifInfo?.exifImageHeight.map { Int($0) }
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    private func cameraName(_ exif: ExifInfo) -> String? {
        let parts = [exif.make, exif.model]
            .compactMap { (value: String?) -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func cameraSpecifications(_ exif: ExifInfo) -> [String] {
        var specifications: [String] = []
        if let focalLength = exif.focalLength {
            specifications.append("\(focalLength.formatted(.number.precision(.fractionLength(0...1)))) mm")
        }
        if let fNumber = exif.fNumber {
            specifications.append("ƒ/\(fNumber.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let exposureTime = exif.exposureTime, !exposureTime.isEmpty {
            specifications.append(exposureTime)
        }
        if let iso = exif.iso {
            specifications.append("ISO \(Int(iso))")
        }
        return specifications
    }

    private func load() async {
        guard let client = session.client else { return }
        loadState = .loading

        do {
            loadState = .loaded(try await client.assetDetail(id: asset.id))
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

import SwiftUI
import MapKit

struct AssetInfoSheet: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset

    @State private var detail: AssetDetail?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(asset.localDate, format: .dateTime.weekday(.wide).month(.wide).day().year().utc())
                    } label: {
                        Label("Date", systemImage: "calendar")
                    }
                    LabeledContent {
                        Text(asset.localDate, format: .dateTime.hour().minute().utc())
                    } label: {
                        Label("Time", systemImage: "clock")
                    }
                }

                if let detail {
                    Section("File") {
                        LabeledContent {
                            Text(detail.originalFileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            Label("Name", systemImage: "doc")
                        }
                        if let w = detail.width ?? detail.exifInfo?.exifImageWidth.map({ Int($0) }),
                           let h = detail.height ?? detail.exifInfo?.exifImageHeight.map({ Int($0) }) {
                            LabeledContent {
                                Text("\(w) × \(h)")
                            } label: {
                                Label("Dimensions", systemImage: "aspectratio")
                            }
                        }
                        if let bytes = detail.exifInfo?.fileSizeInByte {
                            LabeledContent {
                                Text(ByteCountFormatStyle().format(bytes))
                            } label: {
                                Label("Size", systemImage: "internaldrive")
                            }
                        }
                    }

                    if let exif = detail.exifInfo, exif.make != nil || exif.model != nil || exif.fNumber != nil {
                        Section("Camera") {
                            if let make = exif.make, let model = exif.model {
                                LabeledContent {
                                    Text("\(make) \(model)")
                                } label: {
                                    Label("Device", systemImage: "camera")
                                }
                            }
                            if let lens = exif.lensModel {
                                LabeledContent {
                                    Text(lens).lineLimit(1)
                                } label: {
                                    Label("Lens", systemImage: "camera.aperture")
                                }
                            }
                            HStack(spacing: 14) {
                                if let f = exif.fNumber { exifChip("ƒ/\(f.formatted(.number.precision(.fractionLength(0...1))))") }
                                if let exposure = exif.exposureTime { exifChip(exposure) }
                                if let iso = exif.iso { exifChip("ISO \(Int(iso))") }
                                if let focal = exif.focalLength { exifChip("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    if let lat = detail.exifInfo?.latitude, let lon = detail.exifInfo?.longitude {
                        Section("Location") {
                            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            Map(initialPosition: .region(MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            ))) {
                                Marker("", coordinate: coordinate)
                            }
                            .frame(height: 180)
                            .listRowInsets(EdgeInsets())
                            .allowsHitTesting(false)

                            if let place = [detail.exifInfo?.city, detail.exifInfo?.state, detail.exifInfo?.country]
                                .compactMap({ $0 }).filter({ !$0.isEmpty }).nilIfEmpty()?.joined(separator: ", ") {
                                Text(place)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let people = detail.people, !people.isEmpty {
                        Section("People") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(people) { person in
                                        VStack(spacing: 4) {
                                            if let client = session.client {
                                                RemoteImage(url: client.personThumbnailURL(personID: person.id), targetPixelSize: 120)
                                                    .frame(width: 56, height: 56)
                                                    .clipShape(.circle)
                                            }
                                            Text(person.name.isEmpty ? "Unnamed" : person.name)
                                                .font(.caption2)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            detail = try? await session.client?.assetDetail(id: asset.id)
        }
    }

    private func exifChip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

extension Array {
    func nilIfEmpty() -> [Element]? {
        isEmpty ? nil : self
    }
}

import SwiftUI

/// privacy settings: what shared files carry beyond their pixels. the choice
/// is stored locally and applies at export time, when the share sheet
/// prepares its files.
struct PrivacyScreen: View {
    @State private var policy = AssetShareMetadataPolicy.current

    var body: some View {
        List {
            Section {
                Picker("Shared Media", selection: Binding(
                    get: { policy },
                    set: { selected in
                        policy = selected
                        selected.options.persist()
                    }
                )) {
                    ForEach(AssetShareMetadataPolicy.allCases, id: \.self) { choice in
                        Text(choice.title)
                            .tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Shared Media")
            } footer: {
                Text(policy.explanation)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// the three way choice projected onto the stored option pair. the unused
/// fourth combination - metadata stripped but location kept - reads back as
/// removing all metadata.
nonisolated enum AssetShareMetadataPolicy: CaseIterable, Hashable {
    case everything
    case withoutLocation
    case withoutMetadata

    static var current: AssetShareMetadataPolicy {
        let options = AssetShareOptions.current
        if !options.includesAllMetadata { return .withoutMetadata }
        if !options.includesLocation { return .withoutLocation }
        return .everything
    }

    var options: AssetShareOptions {
        switch self {
        case .everything:
            AssetShareOptions(includesLocation: true, includesAllMetadata: true)
        case .withoutLocation:
            AssetShareOptions(includesLocation: false, includesAllMetadata: true)
        case .withoutMetadata:
            AssetShareOptions(includesLocation: false, includesAllMetadata: false)
        }
    }

    var title: String {
        switch self {
        case .everything: "Keep Everything"
        case .withoutLocation: "Remove Location"
        case .withoutMetadata: "Remove All Metadata"
        }
    }

    var explanation: String {
        switch self {
        case .everything:
            "Shared photos and videos keep all of their metadata, including location, capture date and camera information."
        case .withoutLocation:
            "Shared photos and videos are rewritten without their location. Everything else is kept."
        case .withoutMetadata:
            "Shared photos and videos are rewritten without any of their metadata, including location."
        }
    }
}

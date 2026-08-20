import SwiftUI

struct LibraryPersonPreviewCell: View {
    let person: Person

    var body: some View {
        PersonAvatar(person: person, targetPixelSize: LibraryPeoplePreview.thumbnailTargetSize)
            .frame(
                width: LibraryPeoplePreview.portraitSize,
                height: LibraryPeoplePreview.portraitSize
            )
            .frame(width: LibraryPeoplePreview.cellWidth)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}

struct LibraryAllPeoplePreviewCell: View {
    let total: Int

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.12))
            .frame(
                width: LibraryPeoplePreview.portraitSize,
                height: LibraryPeoplePreview.portraitSize
            )
            .overlay {
                VStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                        .font(.title3.weight(.semibold))
                    Text("\(total)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.tint)
            }
            .frame(width: LibraryPeoplePreview.cellWidth)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}

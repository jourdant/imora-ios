import CoreGraphics

nonisolated enum LibraryPeoplePreview {
    private static let maximumPeople = 3
    static let portraitSize: CGFloat = 76
    static let cellWidth: CGFloat = 84
    static let gridSpacing: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let containerPadding: CGFloat = 10
    static let containerCornerRadius: CGFloat = 18
    static let thumbnailTargetSize: CGFloat = 228
    static let gridWidth = cellWidth * 2 + gridSpacing

    static func people(from people: [Person]) -> ArraySlice<Person> {
        people.prefix(maximumPeople)
    }

    static func accessibilityLabel(for person: Person) -> String {
        let name = person.name.isEmpty ? "Unnamed person" : person.name
        guard person.isFavorite == true else { return name }
        return "\(name), favorite"
    }
}

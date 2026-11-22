/// What this build of Carnet shows.
///
/// `.minimal` is the TestFlight cut for the two-person experiment of September
/// 2026: reading only — the Books and Articles shelves, the reader, the share
/// extension that feeds the articles — plus household and member switching.
/// Nothing is deleted: the drawer and the other sections stay in the project
/// and come back by flipping `current` to `.full`.
enum CarnetScope {
    case minimal, full
    static let current: CarnetScope = .minimal
}

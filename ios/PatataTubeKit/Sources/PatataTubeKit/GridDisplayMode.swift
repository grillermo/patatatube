import Foundation

/// One step of the grid's size control: what the button says and what it sets.
/// `nil` from `smaller`/`bigger` is the disabled state.
public struct GridSizeStep: Equatable, Sendable {
    public let title: String
    public let systemImage: String
    public let target: Double

    public init(title: String, systemImage: String, target: Double) {
        self.title = title
        self.systemImage = systemImage
        self.target = target
    }
}

/// How a feed's stored `cellSize` should render.
///
/// The size is one persisted number per feed (`AppModel.cellSize(for:)`), so
/// list mode is a sentinel below the grid floor rather than a second stored
/// flag: nothing about persistence or migration changes, and an older build
/// reading the sentinel just draws 70pt cells.
public enum GridDisplayMode: Equatable, Sendable {
    case list
    case grid(cellSize: Double)

    public static let minCellSize: Double = 170
    public static let maxCellSize: Double = 420
    public static let step: Double = 125
    /// One step below `minCellSize`. Any value under the floor reads as list.
    public static let listCellSize: Double = 70

    /// The 4 sizes a pinch gesture (or repeated menu taps) can land on:
    /// list, then the 3 grid stops `minCellSize`, `minCellSize + step`,
    /// `maxCellSize`. Ascending — `nearestCanonicalSize` relies on the order.
    public static let canonicalSizes: [Double] = [
        listCellSize, minCellSize, minCellSize + step, maxCellSize,
    ]

    /// Constrains a raw size (e.g. `baseSize * pinchScale`) to the range
    /// live rendering is allowed to show — never below list, never above the
    /// biggest grid stop.
    public static func clampedCellSize(_ raw: Double) -> Double {
        min(max(raw, listCellSize), maxCellSize)
    }

    /// Whichever `canonicalSizes` entry is closest to `raw`. Ties resolve to
    /// the smaller neighbor (scans ascending, keeps the first value that
    /// isn't strictly beaten).
    public static func nearestCanonicalSize(to raw: Double) -> Double {
        canonicalSizes.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
    }

    public static func forCellSize(_ size: Double) -> GridDisplayMode {
        size < minCellSize ? .list : .grid(cellSize: size)
    }

    public static func smaller(from size: Double) -> GridSizeStep? {
        switch forCellSize(size) {
        case .list:
            return nil
        case .grid(let size) where size <= minCellSize:
            return GridSizeStep(title: "List view",
                                systemImage: "list.bullet",
                                target: listCellSize)
        case .grid(let size):
            return GridSizeStep(title: "Smaller cells",
                                systemImage: "minus.magnifyingglass",
                                target: max(size - step, minCellSize))
        }
    }

    public static func bigger(from size: Double) -> GridSizeStep? {
        switch forCellSize(size) {
        case .list:
            return GridSizeStep(title: "Grid view",
                                systemImage: "square.grid.2x2",
                                target: minCellSize)
        case .grid(let size) where size >= maxCellSize:
            return nil
        case .grid(let size):
            return GridSizeStep(title: "Bigger cells",
                                systemImage: "plus.magnifyingglass",
                                target: min(size + step, maxCellSize))
        }
    }
}

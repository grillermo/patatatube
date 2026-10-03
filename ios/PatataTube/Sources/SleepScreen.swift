// ios/PatataTube/Sources/SleepScreen.swift
import SwiftUI

/// Play-and-sleep's end state: a black screen that swallows every touch, so a
/// child can't tap back into the app. Playback is already paused, which
/// releases the idle timer, so the device auto-locks on the system schedule.
/// Parents escape by tapping squares of a 2x3 grid in order; each correct tap lights
/// its square, a wrong one blanks them all.
///
/// Drawn by both `RootTabView` and `VideoPlayerView` from the one
/// `AppModel.sleepScreenShown` flag: a `fullScreenCover` sits above anything
/// the root draws, so the player has to draw its own copy.
/// The unlock sequence over a 2-column, 3-row grid. Walking the ring counter-
/// clockwise from top-left gives TL, ML, BL, BR, MR, TR; the code is every
/// other one: top-left, bottom-left, middle-right. A wrong tap (including a
/// skipped-over square) resets to the start.
struct GridUnlock: Equatable {
    static let columns = 2
    static let rows = 3

    struct Cell: Hashable { let column: Int; let row: Int }

    static let sequence = [
        Cell(column: 0, row: 0),
        Cell(column: 0, row: 2),
        Cell(column: 1, row: 1),
    ]

    private(set) var lit: [Cell] = []

    /// Returns true when this tap completes the sequence.
    mutating func tap(_ cell: Cell) -> Bool {
        guard cell == Self.sequence[lit.count] else {
            lit = []
            return false
        }
        lit.append(cell)
        return lit.count == Self.sequence.count
    }

    static func cell(at point: CGPoint, in size: CGSize) -> Cell {
        let column = min(max(Int(point.x / (size.width / CGFloat(columns))), 0), columns - 1)
        let row = min(max(Int(point.y / (size.height / CGFloat(rows))), 0), rows - 1)
        return Cell(column: column, row: row)
    }
}

struct SleepScreen: View {
    let onDismiss: () -> Void

    @State private var unlock = GridUnlock()

    var body: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / CGFloat(GridUnlock.columns)
            let cellHeight = geo.size.height / CGFloat(GridUnlock.rows)
            ZStack {
                Color.black
                // Lit squares only; unlit ones are indistinguishable from the
                // black background so nothing hints where to tap.
                ForEach(unlock.lit, id: \.self) { cell in
                    Color.white
                        .frame(width: cellWidth, height: cellHeight)
                        .position(x: cellWidth * (CGFloat(cell.column) + 0.5),
                                  y: cellHeight * (CGFloat(cell.row) + 0.5))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    let cell = GridUnlock.cell(at: tap.location, in: geo.size)
                    if unlock.tap(cell) { onDismiss() }
                }
            )
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
    }
}

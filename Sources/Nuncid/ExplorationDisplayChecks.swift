import Foundation

enum ExplorationDisplayChecks {
    static func run() -> [String] {
        var failures: [String] = []
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1600, y: -120, width: 1600, height: 1000),
                      CGRect(x: 0, y: 900, width: 1920, height: 1080),
                      CGRect(x: 1440, y: -300, width: 1280, height: 800)]
        let displays = frames.enumerated().map { index, frame in
            ExplorationDisplay(id: UInt32(index + 1), frame: frame,
                content: CGRect(x: frame.minX, y: frame.minY + 24, width: frame.width, height: frame.height - 48),
                quartzBounds: CGRect(x: frame.minX, y: 900 - frame.maxY, width: frame.width, height: frame.height))
        }
        func runs(_ tiles: [ExplorationTile]) -> [UInt32] {
            tiles.reduce(into: []) { result, tile in
                if result.last != tile.display.id { result.append(tile.display.id) }
            }
        }
        for display in displays {
            let pointer = CGPoint(x: display.content.midX, y: display.content.midY)
            let tiles = ExplorationPolicy.scanTiles(on: displays.reversed(), around: pointer)
            let order = ExplorationPolicy.orderedDisplays(displays, around: pointer).map(\.id)
            if order.first != display.id || runs(tiles) != order || tiles.first?.bounds.contains(pointer) != true {
                failures.append("scan all displays sequentially with the invoked display first")
            }
            for target in displays {
                let own = tiles.filter { $0.display.id == target.id }
                let covered = stride(from: target.content.minX + 1, to: target.content.maxX, by: 37).allSatisfy { x in
                    stride(from: target.content.minY + 1, to: target.content.maxY, by: 37).allSatisfy { y in
                        own.contains { $0.bounds.contains(CGPoint(x: x, y: y)) }
                    }
                }
                if !covered || own.isEmpty { failures.append("complete content coverage on left, above and offset displays") }
                for tile in own {
                    guard let plan = target.capturePlan(for: tile.bounds) else {
                        failures.append("every queued tile has its own display capture plan"); continue
                    }
                    if !target.content.contains(tile.bounds) || !target.quartzBounds.contains(plan.rect)
                        || plan.appKitRect(forQuartz: plan.rect) != tile.bounds {
                        failures.append("capture and marker coordinates round-trip on offset displays")
                    }
                }
            }
            let pending = Array(tiles.dropFirst(2))
            let target = displays.first { $0.id != display.id }!
            let reprioritized = ExplorationPolicy.reprioritize(pending, around: CGPoint(x: target.frame.midX, y: target.frame.midY))
            if reprioritized.first?.display.id != target.id || reprioritized.count != pending.count
                || Set(runs(reprioritized)).count != runs(reprioritized).count
                || !pending.allSatisfy({ reprioritized.contains($0) }) {
                failures.append("reprioritization keeps display groups intact without losing queued tiles")
            }
        }
        let mirrored = ExplorationDisplay(id: 99, frame: displays[0].frame, content: displays[0].content, quartzBounds: displays[0].quartzBounds)
        let pointer = CGPoint(x: 100, y: 100)
        if ExplorationPolicy.scanTiles(on: displays + [mirrored], around: pointer) != ExplorationPolicy.scanTiles(on: displays, around: pointer) {
            failures.append("mirrored frames are scanned only once")
        }
        if !ExplorationPolicy.scanTiles(on: [], around: pointer).isEmpty {
            failures.append("no awake displays means no capture work")
        }
        let remaining = Array(displays.dropFirst())
        if runs(ExplorationPolicy.scanTiles(on: remaining, around: pointer)).count != remaining.count {
            failures.append("remaining displays continue when the invocation display disappears")
        }
        for display in displays {
            let bounds = CGRect(x: display.frame.minX + 20, y: display.frame.minY + 50, width: 100, height: 20)
            if ExplorationPolicy.localMarker(bounds, on: display.frame) != CGRect(x: 20, y: 50, width: 100, height: 20)
                || displays.filter({ $0.id != display.id }).contains(where: { ExplorationPolicy.localMarker(bounds, on: $0.frame) != nil }) {
                failures.append("each occurrence draws only on its owning display")
            }
        }
        return failures
    }
}

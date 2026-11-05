// Checks the stacking after an arrangement: for every tile, the topmost window at points inside it must be that
// tile's app. Needs a DEV_HOOKS=1 build, which writes last-arrangement.json. Run: swift Scripts/stackcheck.swift

import CoreGraphics
import Foundation

// For every tile in the last arrangement, the topmost window at points inside it must be that tile's app.
let dumpURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ModernSpectacle/last-arrangement.json")
let dump = try! JSONSerialization.jsonObject(with: Data(contentsOf: dumpURL)) as! [String: Any]
let request = dump["request"] as! [String: Any]
let windows = request["windows"] as! [[String: Any]]
let appOf = Dictionary(uniqueKeysWithValues: windows.map { ($0["id"] as! Int, $0["app"] as! String) })
let placements = (dump["appliedPlan"] as! [String: Any])["placements"] as! [[String: Any]]
let tiles = placements.filter { ($0["group"] as! String).hasPrefix("column") }

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
let onScreen: [(app: String, rect: CGRect)] = list.compactMap { w in
    guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
    let rect = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    return rect.width > 100 ? (w[kCGWindowOwnerName as String] as? String ?? "?", rect) : nil
}
func sameApp(_ a: String, _ b: String) -> Bool { a.hasPrefix(b) || b.hasPrefix(a) }

var problems = 0
for tile in tiles {
    let id = tile["id"] as! Int, app = appOf[id] ?? "?"
    let rect = CGRect(x: tile["x"] as! Int, y: tile["y"] as! Int, width: tile["w"] as! Int, height: tile["h"] as! Int)
    let points = [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.minX + 40, y: rect.minY + 60), CGPoint(x: rect.maxX - 40, y: rect.minY + 60),
                  CGPoint(x: rect.minX + 40, y: rect.maxY - 40), CGPoint(x: rect.maxX - 40, y: rect.maxY - 40)]
    for point in points {
        guard let top = onScreen.first(where: { $0.rect.contains(point) }) else { continue }
        if !sameApp(top.app, app) {
            problems += 1
            print("  COVERED: \(app) tile at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) has \(top.app) \(Int(top.rect.width))x\(Int(top.rect.height)) on top at \(Int(point.x)),\(Int(point.y))")
            break
        }
    }
}
let hidden = placements.filter { ($0["group"] as! String) == "behind" }.map { appOf[$0["id"] as! Int] ?? "?" }
let chrome = onScreen.filter { $0.app == "Google Chrome" && $0.rect.minX < 1920 }
print("  tiles: \(tiles.map { appOf[$0["id"] as! Int] ?? "?" }.joined(separator: ", ")) | hidden: \(hidden.joined(separator: ", ")) | Chrome windows on screen: \(chrome.count) at \(chrome.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" }.joined(separator: "; "))")
print(problems == 0 ? "  STACKING OK: every tile is on top" : "  STACKING FAILED: \(problems) tile(s) covered")

import AppKit
import CoreGraphics
import Foundation

struct StatusItemWindowSnapshot:
    Equatable,
    CustomStringConvertible
{
    let name: String
    let ownerName: String
    let bounds: CGRect
    let isOnscreen: Bool
    let displayBounds: CGRect?

    var isWithinDisplayBounds: Bool {
        guard let displayBounds else {
            return false
        }
        return displayBounds.contains(bounds)
    }

    var isTahoeBlockedProxy: Bool {
        ownerName == "Control Center"
            && isOnscreen
            && abs(bounds.minX) <= 1
            && bounds.maxY <= 0
            && bounds.width > 0
            && bounds.height > 0
            && !isWithinDisplayBounds
    }

    var description: String {
        "name=\(name),owner=\(ownerName),"
            + "x=\(Int(bounds.minX)),y=\(Int(bounds.minY)),"
            + "w=\(Int(bounds.width)),h=\(Int(bounds.height)),"
            + "onscreen=\(isOnscreen),withinDisplay=\(isWithinDisplayBounds)"
    }
}

enum StatusItemWindowProbe {
    static func snapshots(
        matching names: Set<String>
    ) -> [StatusItemWindowSnapshot] {
        guard
            let windowInfo =
                CGWindowListCopyWindowInfo(
                    [.optionAll],
                    kCGNullWindowID
                ) as? [[String: Any]]
        else {
            return []
        }
        return snapshots(
            matching: names,
            windowInfo: windowInfo,
            displayBounds:
                displayBoundsInWindowServerCoordinates()
        )
    }

    static func snapshots(
        matching names: Set<String>,
        windowInfo: [[String: Any]],
        displayBounds: [CGRect]
    ) -> [StatusItemWindowSnapshot] {
        guard !names.isEmpty else {
            return []
        }
        return windowInfo.compactMap {
            snapshot(
                record: $0,
                matching: names,
                displayBounds: displayBounds
            )
        }
    }

    private static func snapshot(
        record: [String: Any],
        matching names: Set<String>,
        displayBounds: [CGRect]
    ) -> StatusItemWindowSnapshot? {
        guard
            let name =
                record[
                    kCGWindowName as String
                ] as? String,
            names.contains(name),
            let bounds =
                cgRect(
                    record[
                        kCGWindowBounds as String
                    ]
                )
        else {
            return nil
        }
        let ownerName =
            record[
                kCGWindowOwnerName as String
            ] as? String
            ?? "unknown"
        let isOnscreen =
            (
                record[
                    kCGWindowIsOnscreen as String
                ] as? NSNumber
            )?.boolValue
            ?? record[
                kCGWindowIsOnscreen as String
            ] as? Bool
            ?? false
        return StatusItemWindowSnapshot(
            name: name,
            ownerName: ownerName,
            bounds: bounds,
            isOnscreen: isOnscreen,
            displayBounds:
                displayBounds.first {
                    $0.intersects(bounds)
                }
        )
    }

    private static func cgRect(
        _ value: Any?
    ) -> CGRect? {
        guard
            let dictionary =
                value as? [String: Any],
            let x = double(dictionary["X"]),
            let y = double(dictionary["Y"]),
            let width =
                double(dictionary["Width"]),
            let height =
                double(dictionary["Height"])
        else {
            return nil
        }
        return CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private static func displayBoundsInWindowServerCoordinates()
        -> [CGRect]
    {
        NSScreen.screens.compactMap { screen in
            let key =
                NSDeviceDescriptionKey(
                    "NSScreenNumber"
                )
            guard
                let number =
                    screen.deviceDescription[key]
                        as? NSNumber
            else {
                return nil
            }
            return CGDisplayBounds(
                CGDirectDisplayID(
                    number.uint32Value
                )
            )
        }
    }

    private static func double(
        _ value: Any?
    ) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let double as Double:
            double
        case let int as Int:
            Double(int)
        case let cgFloat as CGFloat:
            Double(cgFloat)
        default:
            nil
        }
    }
}

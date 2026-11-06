import CoreGraphics

/// Named screen regions a window can snap into.
enum SnapZone: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center

    /// The zone's rect inside a screen's visible frame. Both are in Cocoa coordinates (y up).
    func rect(in v: CGRect) -> CGRect {
        let halfW = (v.width / 2).rounded()
        let halfH = (v.height / 2).rounded()
        switch self {
        case .leftHalf:    return CGRect(x: v.minX, y: v.minY, width: halfW, height: v.height)
        case .rightHalf:   return CGRect(x: v.minX + halfW, y: v.minY, width: v.width - halfW, height: v.height)
        case .topHalf:     return CGRect(x: v.minX, y: v.minY + halfH, width: v.width, height: v.height - halfH)
        case .bottomHalf:  return CGRect(x: v.minX, y: v.minY, width: v.width, height: halfH)
        case .topLeft:     return CGRect(x: v.minX, y: v.minY + halfH, width: halfW, height: v.height - halfH)
        case .topRight:    return CGRect(x: v.minX + halfW, y: v.minY + halfH, width: v.width - halfW, height: v.height - halfH)
        case .bottomLeft:  return CGRect(x: v.minX, y: v.minY, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: v.minX + halfW, y: v.minY, width: v.width - halfW, height: halfH)
        case .maximize:    return v
        case .center:
            let w = (v.width * 2 / 3).rounded(), h = (v.height * 3 / 4).rounded()
            return CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        }
    }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .maximize: return "Maximize"
        case .center: return "Center"
        }
    }
}

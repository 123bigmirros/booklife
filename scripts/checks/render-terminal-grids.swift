import AppKit
import Foundation
let directory = URL(fileURLWithPath:CommandLine.arguments[1])
for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where url.pathExtension == "json" {
    let data = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    let cols = data["cols"] as! Int, rows = data["rows"] as! Int
    let grid = data["cells"] as! [[[Any]]]
    let cellWidth:CGFloat = 10, cellHeight:CGFloat = 24, padding:CGFloat = 16
    let size = NSSize(width:CGFloat(cols)*cellWidth+padding*2,height:CGFloat(rows)*cellHeight+padding*2)
    let image = NSImage(size:size)
    image.lockFocus()
    let background = NSColor(calibratedWhite:0.08,alpha:1), foreground = NSColor(calibratedWhite:0.88,alpha:1)
    background.setFill(); NSRect(origin:.zero,size:size).fill()
    for row in 0..<rows {
        for col in 0..<cols where grid[row][col][3] as! Bool {
            foreground.setFill()
            NSRect(x:padding+CGFloat(col)*cellWidth,y:size.height-padding-CGFloat(row+1)*cellHeight,width:cellWidth,height:cellHeight).fill()
        }
    }
    for row in 0..<rows {
        for col in 0..<cols {
            let cell = grid[row][col], value = cell[0] as! String
            let dim = cell[1] as! Bool, bold = cell[2] as! Bool, inverse = cell[3] as! Bool
            let point = NSPoint(x:padding+CGFloat(col)*cellWidth,y:size.height-padding-CGFloat(row+1)*cellHeight)
            if !value.isEmpty {
                (value as NSString).draw(at:point,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:16,weight:bold ? .semibold : .regular),.foregroundColor:inverse ? background : (dim ? NSColor(calibratedWhite:0.55,alpha:1) : foreground)])
            }
        }
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
    try bitmap.representation(using:.png,properties:[:])!.write(to:url.deletingPathExtension().appendingPathExtension("png"))
}

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 9,
      let screenWidth = Double(args[2]), let screenHeight = Double(args[3]),
      let x = Double(args[4]), let y = Double(args[5]),
      let width = Double(args[6]), let height = Double(args[7]),
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Invalid screenshot or companion rectangle")
}

let scaleX = Double(image.width) / screenWidth
let scaleY = Double(image.height) / screenHeight
let center = CGPoint(x: (x + width / 2) * scaleX, y: (y + height / 2) * scaleY)
let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
let region = CGRect(x: center.x - 18 * scaleX, y: center.y - 12 * scaleY,
                    width: 36 * scaleX, height: 32 * scaleY).integral.intersection(bounds)
guard !region.isEmpty, let sample = image.cropping(to: region) else {
    fatalError("Companion rectangle is outside the screenshot")
}

let pixelCount = sample.width * sample.height
var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
    guard let canvas = CGContext(data: bytes.baseAddress, width: sample.width, height: sample.height,
                                 bitsPerComponent: 8, bytesPerRow: sample.width * 4,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    canvas.draw(sample, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
    return true
}
precondition(decoded, "Could not decode screenshot pixels")
let target = args[8] == "devil" ? (233, 147, 134) : (155, 200, 220)
var match = 0
var faceDetails = 0
for offset in stride(from: 0, to: pixels.count, by: 4) {
    let red = Int(pixels[offset])
    let green = Int(pixels[offset + 1])
    let blue = Int(pixels[offset + 2])
    let dr = red - target.0, dg = green - target.1, db = blue - target.2
    if dr * dr + dg * dg + db * db < 28 * 28 { match += 1 }
    if max(red, green, blue) < 160 { faceDetails += 1 }
}
guard match > pixelCount / 8, faceDetails > pixelCount / 150 else {
    fatalError("No recognizable \(args[8]) companion at \(region)")
}

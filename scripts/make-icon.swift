// 앱 아이콘을 코드로 그려 AppIcon.appiconset 에 크기별 PNG 와 Contents.json 을 만든다.
//   swift scripts/make-icon.swift [출력 폴더]   (기본: GazeNotification/Assets.xcassets/AppIcon.appiconset)
//
// 디자인: 남보라 배경 위의 눈 하나, 그 시선이 향하는 왼쪽 위로 알림 배너가 미끄러져 온다.
// 크기마다 벡터로 다시 그려서 작은 크기도 흐려지지 않는다. 좌표는 1024pt 캔버스, 왼쪽 위 원점.
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                 ?? "GazeNotification/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// macOS 아이콘과 같은 연속 곡률 모서리
func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func circle(_ center: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
}

func eyePath(center: CGPoint, halfWidth w: CGFloat, lift: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let left = CGPoint(x: center.x - w, y: center.y), right = CGPoint(x: center.x + w, y: center.y)
    p.move(to: left)
    p.addCurve(to: right, control1: CGPoint(x: center.x - w * 0.5, y: center.y - lift),
               control2: CGPoint(x: center.x + w * 0.5, y: center.y - lift))
    p.addCurve(to: left, control1: CGPoint(x: center.x + w * 0.5, y: center.y + lift),
               control2: CGPoint(x: center.x - w * 0.5, y: center.y + lift))
    p.closeSubpath()
    return p
}

func drawIcon(_ ctx: CGContext, pixels: Int) {
    let s = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)

    // 그림자 오프셋·블러는 CTM 의 영향을 받지 않아 픽셀 단위로 직접 맞춘다 (음수 height = 아래쪽)
    func shadow(y: CGFloat, blur: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -y * s), blur: blur * s, color: c)
    }

    // 배경
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    shadow(y: 10, blur: 22, color(0x000000, 0.35))
    ctx.addPath(tile); ctx.setFillColor(color(0x4A55D8)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x6F8DFF)), (0.55, color(0x4F4FD6)), (1, color(0x33228F))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.22)), (1, color(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: 380, y: 180), startRadius: 0,
                           endCenter: CGPoint(x: 380, y: 180), endRadius: 520, options: [])
    ctx.restoreGState()

    // 알림 배너: 오른쪽에서 미끄러져 오는 잔상 두 개 + 본체
    let banner = CGRect(x: 168, y: 192, width: 400, height: 136)
    for (dx, alpha) in [(236.0, 0.10), (118.0, 0.24)] {
        ctx.addPath(roundedRect(banner.offsetBy(dx: dx, dy: 0), 42))
        ctx.setFillColor(color(0xFFFFFF, alpha)); ctx.fillPath()
    }
    ctx.saveGState()
    shadow(y: 8, blur: 20, color(0x140A50, 0.35))
    ctx.addPath(roundedRect(banner, 42)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(banner, 42)); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF)), (1, color(0xEEF0FF))]),
                           start: CGPoint(x: 0, y: banner.minY), end: CGPoint(x: 0, y: banner.maxY), options: [])
    ctx.restoreGState()

    let glyph = CGRect(x: banner.minX + 26, y: banner.midY - 42, width: 84, height: 84)
    ctx.saveGState()
    ctx.addPath(roundedRect(glyph, 22)); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFC046)), (1, color(0xFF5577))]),
                           start: CGPoint(x: glyph.minX, y: glyph.minY), end: CGPoint(x: glyph.maxX, y: glyph.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(roundedRect(CGRect(x: glyph.maxX + 26, y: banner.midY - 30, width: 210, height: 24), 12))
    ctx.setFillColor(color(0x2A2E5C, 0.85)); ctx.fillPath()
    ctx.addPath(roundedRect(CGRect(x: glyph.maxX + 26, y: banner.midY + 10, width: 150, height: 22), 11))
    ctx.setFillColor(color(0x2A2E5C, 0.3)); ctx.fillPath()

    // 눈: 동공이 배너 쪽(왼쪽 위)을 본다
    let eyeCenter = CGPoint(x: 512, y: 628)
    let eye = eyePath(center: eyeCenter, halfWidth: 310, lift: 195)
    ctx.saveGState()
    shadow(y: 14, blur: 34, color(0x120A40, 0.45))
    ctx.addPath(eye); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(eye); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF)), (1, color(0xD9E0FF))]),
                           start: CGPoint(x: 0, y: eyeCenter.y - 140), end: CGPoint(x: 0, y: eyeCenter.y + 140), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let iris = CGPoint(x: eyeCenter.x - 62, y: eyeCenter.y - 40)
    let irisR: CGFloat = 128
    ctx.drawRadialGradient(gradient([(0, color(0x6BE6FF)), (0.62, color(0x2F86FF)), (1, color(0x1D3BB5))]),
                           startCenter: iris, startRadius: 0, endCenter: iris, endRadius: irisR, options: [])
    ctx.addEllipse(in: circle(iris, irisR - 3))
    ctx.setStrokeColor(color(0x13277A, 0.55)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.addEllipse(in: circle(iris, 56)); ctx.setFillColor(color(0x0D1036)); ctx.fillPath()
    ctx.addEllipse(in: circle(CGPoint(x: iris.x + 40, y: iris.y - 42), 25)); ctx.setFillColor(color(0xFFFFFF, 0.95)); ctx.fillPath()
    ctx.addEllipse(in: circle(CGPoint(x: iris.x - 42, y: iris.y + 44), 11)); ctx.setFillColor(color(0xFFFFFF, 0.55)); ctx.fillPath()

    // 윗눈꺼풀이 드리우는 그늘
    ctx.drawLinearGradient(gradient([(0, color(0x1A1460, 0.22)), (1, color(0x1A1460, 0))]),
                           start: CGPoint(x: 0, y: eyeCenter.y - 140), end: CGPoint(x: 0, y: eyeCenter.y - 40), options: [.drawsBeforeStartLocation])
    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(ctx, pixels: pixels)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try renderPNG(pixels: points * scale, to: outDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("저장: \(outDir.path)")

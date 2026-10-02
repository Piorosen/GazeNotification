import AppKit
// 사용법: cards <png> <x(px)> — 세로줄 x 에서 배경과 색이 다른 구간(카드)을 찾아 y 범위를 출력한다
let args = CommandLine.arguments
let rep = NSImage(contentsOfFile: args[1])!.representations[0] as! NSBitmapImageRep
let x = Int(args[2])!
func lum(_ y: Int) -> Int {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return Int((c.redComponent * 0.3 + c.greenComponent * 0.59 + c.blueComponent * 0.11) * 255)
}
let bg = lum(5)
var start: Int? = nil
var runs: [(Int, Int)] = []
for y in 0..<rep.pixelsHigh {
    let different = abs(lum(y) - bg) >= 3
    if different, start == nil { start = y }
    if !different, let s = start { if y - s > 30 { runs.append((s, y)) }; start = nil }
}
print("bg", bg, "size", rep.pixelsWide, rep.pixelsHigh)
// 카드 안의 구분선(1~2px)으로 끊긴 구간은 합친다
var merged: [(Int, Int)] = []
for r in runs {
    if let last = merged.last, r.0 - last.1 < 8 { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
}
for r in merged { print(r.0, r.1, r.1 - r.0) }

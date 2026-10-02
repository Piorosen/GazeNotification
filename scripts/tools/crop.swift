import AppKit
// 사용법: crop <입력.png> <출력.png> x y w h  (px, 위 기준)
let a = CommandLine.arguments
let rep = NSImage(contentsOfFile: a[1])!.representations[0] as! NSBitmapImageRep
let image = rep.cgImage!
let r = CGRect(x: Int(a[3])!, y: Int(a[4])!, width: Int(a[5])!, height: min(Int(a[6])!, image.height - Int(a[4])!))
try! NSBitmapImageRep(cgImage: image.cropping(to: r)!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))

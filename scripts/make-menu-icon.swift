// Makes Resources/MenuIcon.png: Hermes' app icon (the girl's head) as a menu bar silhouette at
// 36 px = 18 pt @2x: solid hair, with the face, neck and headband cut out. Fine detail is dropped
// on purpose: at menu bar size it turns to mush.
// The app draws the status badge on top at runtime.
//   swift scripts/make-menu-icon.swift [path to Hermes icon-mac.png]
import AppKit

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/.hermes/hermes-agent/apps/desktop/assets/icon-mac.png"
guard let src = NSImage(contentsOfFile: path) else { print("Can't read \(path)"); exit(1) }

let n = 512, out = 36, gap = 6   // gap: px of white line (the headband) to bridge at 512 px
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
var r = NSRect(origin: .zero, size: src.size)
ctx.draw(src.cgImage(forProposedRect: &r, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: n, height: n))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)

var ink = [Bool](repeating: false, count: n * n)
for i in 0..<(n * n) { ink[i] = px[i*4+3] > 128 && Int(px[i*4]) + Int(px[i*4+1]) + Int(px[i*4+2]) < 300 }

func grow(_ m: [Bool], by k: Int, _ value: Bool) -> [Bool] {   // dilate (true) or erode (false), square kernel
    var res = m
    for y in 0..<n { for x in 0..<n where m[y*n+x] != value {
        outer: for dy in -k...k { for dx in -k...k {
            let xx = x + dx, yy = y + dy
            if xx >= 0, yy >= 0, xx < n, yy < n, m[yy*n+xx] == value { res[y*n+x] = value; break outer }
        }}
    }}
    return res
}

// Thicken the ink so thin white lines inside the figure close up, flood the paper from the edges,
// and call everything the flood can't reach "figure". Then shrink back by the same amount.
let walls = grow(ink, by: gap, true)
var outside = [Bool](repeating: false, count: n * n)
var stack: [Int] = []
for i in 0..<n { stack += [i, (n-1)*n + i, i*n, i*n + n - 1] }
while let p = stack.popLast() {
    if outside[p] || walls[p] { continue }
    outside[p] = true
    let x = p % n, y = p / n
    if x > 0 { stack.append(p - 1) }; if x < n - 1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - n) }; if y < n - 1 { stack.append(p + n) }
}
let figure = grow(outside.map { !$0 }, by: gap, false)

// Cut the big white areas inside the figure back out (face, neck, headband) so it still reads
// as her; tiny ones (hair highlights) are dropped because they turn to noise at 18 pt.
let minHole = 1500, smooth = 2
var label = [Int](repeating: -1, count: n * n), sizes: [Int] = []
for s in 0..<(n * n) where figure[s] && !ink[s] && label[s] < 0 {
    var st = [s], count = 0
    let id = sizes.count
    label[s] = id
    while let p = st.popLast() {
        count += 1
        let x = p % n, y = p / n
        for q in [x > 0 ? p - 1 : -1, x < n - 1 ? p + 1 : -1, y > 0 ? p - n : -1, y < n - 1 ? p + n : -1]
        where q >= 0 && figure[q] && !ink[q] && label[q] < 0 {
            label[q] = id
            st.append(q)
        }
    }
    sizes.append(count)
}
var hole = (0..<(n * n)).map { label[$0] >= 0 && sizes[label[$0]] >= minHole }
hole = grow(grow(hole, by: smooth, false), by: smooth, true)   // shave slivers off the holes

var minX = n, minY = n, maxX = 0, maxY = 0
for i in 0..<(n * n) {
    let on = figure[i] && !hole[i]
    px[i*4] = 0; px[i*4+1] = 0; px[i*4+2] = 0; px[i*4+3] = on ? 255 : 0
    if figure[i] { let x = i % n, y = i / n; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}
let side = max(maxX - minX, maxY - minY) + 4
let crop = CGRect(x: (minX + maxX) / 2 - side / 2, y: (minY + maxY) / 2 - side / 2, width: side, height: side)
let cropped = ctx.makeImage()!.cropping(to: crop)!   // CGImage rows run top-down; the box is symmetric

let small = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: out * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
small.interpolationQuality = .high
small.draw(cropped, in: CGRect(x: 0, y: 0, width: out, height: out))
let rep = NSBitmapImageRep(cgImage: small.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/MenuIcon.png"))
print("Wrote Resources/MenuIcon.png")

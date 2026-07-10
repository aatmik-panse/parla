#!/bin/bash
# Regenerate Resources/AppIcon.icns + Resources/menubar.png from Resources/parla.svg.
# The SVG is a dark #1a1a1a tile with the waveform logo as an embedded JPEG; we pull
# that JPEG out and render two derivatives: a Big Sur squircle icon and a menu-bar
# template silhouette. Run after changing the logo. Needs macOS (sips/iconutil/swift).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)

# 1. Extract the embedded artwork from the SVG.
python3 - "$T/art.jpg" <<'PY'
import re, base64, sys, pathlib
svg = pathlib.Path("Resources/parla.svg").read_text()
data = base64.b64decode(re.search(r'href="data:image/jpeg;base64,([^"]+)"', svg).group(1))
pathlib.Path(sys.argv[1]).write_bytes(data)
PY

# 2. Squircle app icon (1024) — dark art centre-cropped into a rounded rect.
swift - "$T/art.jpg" "$T/icon.png" <<'SWIFT'
import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let sw = src.size.width, sh = src.size.height
let canvas = 1024, margin = 100.0, side = 1024.0 - 200, radius = (1024.0 - 200) * 0.2237
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: margin, y: margin, width: side, height: side)
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1).setFill()
path.fill(); path.setClip()
let cs = min(sw, sh)
src.draw(in: rect, from: NSRect(x: (sw-cs)/2, y: (sh-cs)/2, width: cs, height: cs),
         operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT

# 3. Menu-bar template — white waveform on transparent, trimmed to its bbox.
swift - "$T/art.jpg" Resources/menubar.png <<'SWIFT'
import AppKit
import CoreGraphics
let cg = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height, cs = CGColorSpaceCreateDeviceRGB()
var buf = [UInt8](repeating: 0, count: w*h*4)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
var out = [UInt8](repeating: 0, count: w*h*4)
var minX = w, minY = h, maxX = -1, maxY = -1
for i in 0..<(w*h) {
    let lum = (0.299*Double(buf[i*4]) + 0.587*Double(buf[i*4+1]) + 0.114*Double(buf[i*4+2])) / 255.0
    let a = UInt8(max(0, min(1, (lum - 0.2) / 0.6)) * 255)  // dark bg -> 0, white -> 1
    out[i*4]=a; out[i*4+1]=a; out[i*4+2]=a; out[i*4+3]=a
    if a > 127 { let x=i%w, y=i/w; minX=min(minX,x); maxX=max(maxX,x); minY=min(minY,y); maxY=max(maxY,y) }
}
let octx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let crop = octx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1))!
try! NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT

# 4. Build the .icns from the squircle master.
ICO="$T/Parla.iconset"; mkdir -p "$ICO"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon.png" --out "$ICO/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$ICO/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICO" -o Resources/AppIcon.icns
rm -rf "$T"
echo "Wrote Resources/AppIcon.icns and Resources/menubar.png"

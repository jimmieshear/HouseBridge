#!/bin/zsh
# Regenerates Resources/AppIcon.icns from Resources/AppIcon-source.png (the artwork isn't square, so it is
# centered on a 1024 canvas at the standard macOS icon size, 824 pt, with transparent margin).
# The .icns is committed; only rerun this when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Resources/AppIcon-source.png
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/pad.swift" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard let src = NSImage(contentsOfFile: a[1]) else { fatalError("cannot read \(a[1])") }
let canvas = 1024.0, body = 824.0
let scale = body / max(src.size.width, src.size.height)
let w = src.size.width * scale, h = src.size.height * scale
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: NSRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swiftc -O "$WORK/pad.swift" -o "$WORK/pad"
"$WORK/pad" "$SRC" "$WORK/icon1024.png"

SET="$WORK/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"

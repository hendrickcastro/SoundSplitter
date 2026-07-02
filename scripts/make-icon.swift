#!/usr/bin/env swift
// Renders the SoundSplitter app icon (1024×1024 PNG) with CoreGraphics.
// Motif: one source node splitting into two outputs — an "audio splitter" —
// with sound waves, on a blue→violet gradient squircle.
// Usage: swift scripts/make-icon.swift <output.png>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}
let white = rgb(255, 255, 255)

// Rounded-square (squircle-ish) clip.
let rect = CGRect(x: 0, y: 0, width: S, height: S)
let bg = CGPath(roundedRect: rect, cornerWidth: 228, cornerHeight: 228, transform: nil)
ctx.addPath(bg)
ctx.clip()

// Diagonal gradient background: blue → violet.
let grad = CGGradient(colorsSpace: cs,
                      colors: [rgb(59, 130, 246), rgb(139, 92, 246)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// Subtle top gloss.
ctx.saveGState()
let gloss = CGGradient(colorsSpace: cs,
                       colors: [rgb(255, 255, 255, 0.18), rgb(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: CGFloat(S)), end: CGPoint(x: 0, y: CGFloat(S) * 0.55), options: [])
ctx.restoreGState()

// Node positions (CoreGraphics origin is bottom-left).
let left  = CGPoint(x: 322, y: 512)
let top   = CGPoint(x: 712, y: 690)
let bot   = CGPoint(x: 712, y: 334)

// Connectors: source → two outputs (rounded, white).
ctx.setStrokeColor(white)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(52)
ctx.move(to: left)
ctx.addCurve(to: top, control1: CGPoint(x: 520, y: 512), control2: CGPoint(x: 560, y: 690))
ctx.move(to: left)
ctx.addCurve(to: bot, control1: CGPoint(x: 520, y: 512), control2: CGPoint(x: 560, y: 334))
ctx.strokePath()

// Nodes (filled circles).
ctx.setFillColor(white)
func dot(_ c: CGPoint, _ r: CGFloat) {
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2))
}
dot(left, 66)
dot(top, 52)
dot(bot, 52)

// Sound waves radiating from each output node.
ctx.setLineCap(.round)
func waves(at c: CGPoint) {
    for (i, r) in [86.0, 132.0].enumerated() {
        ctx.setLineWidth(i == 0 ? 26 : 22)
        ctx.setStrokeColor(rgb(255, 255, 255, i == 0 ? 0.95 : 0.6))
        ctx.addArc(center: c, radius: r,
                   startAngle: -0.62, endAngle: 0.62, clockwise: false)
        ctx.strokePath()
    }
}
waves(at: top)
waves(at: bot)

guard let image = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no destination")
}
CGImageDestinationAddImage(dest, image, nil)
if CGImageDestinationFinalize(dest) {
    print("wrote \(outPath)")
} else {
    fatalError("write failed")
}

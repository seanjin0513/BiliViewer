#!/usr/bin/env swift
// 生成 BiliViewer 应用图标:圆角矩形蓝色背景 + 白色电视机轮廓 + 弹幕线条
import AppKit
import CoreGraphics

let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create context")
}
let s = CGFloat(size)

// 背景:圆角矩形,B站粉蓝渐变(实际用 B 站蓝粉渐变 #FB7299 → #23ADE5)
let rect = CGRect(x: 0, y: 0, width: s, height: s)
let radius = s * 0.225 // macOS 图标标准圆角比例
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(bg)
ctx.clip()

let colors = [CGColor(red: 0.984, green: 0.447, blue: 0.600, alpha: 1.0),
              CGColor(red: 0.137, green: 0.678, blue: 0.898, alpha: 1.0)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0.0, 1.0])!
// 对角渐变:左上粉 → 右下蓝
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// 电视机(居中):屏幕圆角矩形 + 底部两个支撑脚
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let tvW = s * 0.56, tvH = s * 0.40
let tvX = (s - tvW) / 2, tvY = s * 0.30
let tvRect = CGRect(x: tvX, y: tvY, width: tvW, height: tvH)
ctx.addPath(CGPath(roundedRect: tvRect, cornerWidth: tvH * 0.18, cornerHeight: tvH * 0.18, transform: nil))
ctx.fillPath()
// 屏幕内部(B站色)
ctx.setFillColor(CGColor(red: 0.984, green: 0.447, blue: 0.600, alpha: 1.0))
let inset = tvH * 0.09
let screen = CGRect(x: tvX + inset, y: tvY + inset, width: tvW - inset * 2, height: tvH - inset * 2)
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: tvH * 0.12, cornerHeight: tvH * 0.12, transform: nil))
ctx.fillPath()

// 支撑脚
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let footW = s * 0.035, footH = s * 0.075
ctx.fill(CGRect(x: tvX + tvW * 0.12, y: tvY - footH * 0.9, width: footW, height: footH))
ctx.fill(CGRect(x: tvX + tvW * 0.88 - footW, y: tvY - footH * 0.9, width: footW, height: footH))

// 天线:两条斜线从机顶伸出
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(s * 0.028)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: s * 0.42, y: tvY + tvH))
ctx.addLine(to: CGPoint(x: s * 0.30, y: s * 0.80))
ctx.strokePath()
ctx.move(to: CGPoint(x: s * 0.58, y: tvY + tvH))
ctx.addLine(to: CGPoint(x: s * 0.70, y: s * 0.80))
ctx.strokePath()

// 弹幕:屏幕内三条白色圆角短条
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
func danmu(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                       cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.fillPath()
}
danmu(screen.minX + screen.width * 0.10, screen.midY - screen.height * 0.05 + screen.height * 0.12, screen.width * 0.42, screen.height * 0.11)
danmu(screen.minX + screen.width * 0.10, screen.midY - screen.height * 0.12, screen.width * 0.30, screen.height * 0.11)
danmu(screen.minX + screen.width * 0.10, screen.midY - screen.height * 0.35, screen.width * 0.50, screen.height * 0.11)

// 输出 PNG
guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("icon written to \(out)")

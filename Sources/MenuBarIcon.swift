import AppKit

let monitorGaugeIcon: NSImage = {
    let size = NSSize(width: 18, height: 18)
    let url = Bundle.main.url(forResource: "Gauge", withExtension: "svg")
    let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: size)
    image.size = size
    image.isTemplate = true
    image.accessibilityDescription = "副屏监视器"
    return image
}()

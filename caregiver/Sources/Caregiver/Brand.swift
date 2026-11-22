import AppKit
import SwiftUI

enum Brand {
    static let navy = Color(red: 6.0 / 255, green: 38.0 / 255, blue: 77.0 / 255)
    static let gold = Color(red: 242.0 / 255, green: 181.0 / 255, blue: 59.0 / 255)
    static let blue = Color(red: 66.0 / 255, green: 110.0 / 255, blue: 154.0 / 255)
    static let muted = Color(red: 143.0 / 255, green: 175.0 / 255, blue: 189.0 / 255)
    static let paleBlue = Color(red: 178.0 / 255, green: 209.0 / 255, blue: 226.0 / 255)
    static let cream = Color(red: 250.0 / 255, green: 240.0 / 255, blue: 220.0 / 255)
    static let background = Color(red: 0.031, green: 0.063, blue: 0.106)
    static let surface = Color(red: 0.052, green: 0.10, blue: 0.164)
    static let raised = Color(red: 0.074, green: 0.145, blue: 0.235)
    static let line = Color(red: 0.16, green: 0.23, blue: 0.33)
    static let secondaryText = Color(red: 0.70, green: 0.77, blue: 0.84)

    static func logo(_ name: String) -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct BrandHeader: View {
    @ScaledMetric(relativeTo: .title) private var emblemWidth = 96.0

    private var emblemSize: Double { min(emblemWidth, 108) }

    var body: some View {
        BrandWordmark()
            .padding(.horizontal, emblemSize + 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                BrandEmblem()
                    .frame(width: emblemSize, height: emblemSize)
            }
    }
}

private struct BrandWordmark: View {
    @ScaledMetric(relativeTo: .largeTitle) private var markWidth = 438.0

    var body: some View {
        if let logo = Brand.logo("SAHANA-wordmark") {
            Color.clear
                .aspectRatio(logo.size.width / logo.size.height, contentMode: .fit)
                .overlay {
                    Brand.gold.mask {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFit()
                            .saturation(0)
                            .colorInvert()
                            .contrast(1.35)
                            .luminanceToAlpha()
                    }
                }
                .frame(maxWidth: min(markWidth, 485))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("SAHANA"))
        }
    }
}

struct BrandEmblem: View {
    var body: some View {
        if let logo = Brand.logo("SAHANA-emblem") {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}

struct MessageBanner: View {
    let message: String
    let symbol: String
    var background: Color = Brand.raised

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct GoldActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(Brand.navy)
            .background(Brand.gold.opacity(configuration.isPressed ? 0.76 : 1),
                        in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.5)
    }
}

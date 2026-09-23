import AppKit
import SwiftUI

struct MapPreview: View {
    @Bindable var store: MaterialLabStore
    let source: MaterialSource
    @State private var showTiling = false
    @State private var showRelighting = false
    @State private var lightAngle: Float = 0.6
    @State private var relitImage: NSImage?

    private var material: DerivedMaterial? {
        guard store.derived?.source.id == source.id else { return nil }
        return store.derived
    }

    private var shownImage: NSImage? {
        if showRelighting { return relitImage }
        if let map = material?.maps[store.selectedMap] {
            return MaterialEngine.previewImage(map)
        }
        return NSImage(contentsOf: source.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Map preview").font(.headline)
                Spacer()
                Toggle("3×3 tile", isOn: $showTiling)
                    .toggleStyle(.checkbox)
                Toggle("Relight", isOn: $showRelighting)
                    .toggleStyle(.checkbox)
                    .disabled(material?.maps[.normal] == nil)
            }
            if let material {
                Picker("Map", selection: $store.selectedMap) {
                    ForEach(MaterialMapKind.allCases.filter { material.maps[$0] != nil }) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)
                if showRelighting {
                    HStack {
                        Text("Light direction").font(.caption)
                        Slider(value: $lightAngle, in: -3.14...3.14)
                            .frame(maxWidth: 220)
                    }
                }
            }
            if let image = shownImage {
                Group {
                    if showTiling {
                        TileGrid(image: image)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 480)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(showTiling ? "Three by three material tile preview" : "Material map preview")
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
                    .frame(height: 480)
            }
            if let material {
                HStack {
                    Text("\(material.maps.count) maps · \(material.algorithmVersion)")
                    Spacer()
                    Text("Source SHA-256: \(material.sourceSHA256.prefix(12))…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(store.derivationSerial):\(lightAngle)") {
            guard let material else { relitImage = nil; return }
            relitImage = MaterialEngine.relitPreview(material, azimuth: lightAngle)
        }
    }
}

private struct TileGrid: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { column in
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: side / 3, height: side / 3)
                                .accessibilityHidden(row != 1 || column != 1)
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

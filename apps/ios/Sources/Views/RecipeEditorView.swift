import SwiftUI

/// Recipe controls grouped by intent. Every edit re-derives the live preview after a short debounce.
struct RecipeEditorView: View {
    @Bindable var store: CaptureStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Material prior", selection: Binding(get: { store.recipe.preset },
                                                                set: { store.setPreset($0) })) {
                        ForEach(MaterialPreset.allCases) { preset in
                            Label(preset.title, systemImage: preset.symbol).tag(preset)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("Switching the prior resets relief and surface values to that material's defaults.")
                }

                Section {
                    RecipeSlider(title: "Height", symbol: "mountain.2", value: $store.recipe.heightStrength,
                                 range: MaterialRecipe.heightStrengthRange, step: 0.01)
                    Picker(selection: $store.recipe.heightPolarity) {
                        Text("Raised").tag(Int32(1))
                        Text("Inset").tag(Int32(-1))
                    } label: {
                        Label("Bright features", systemImage: "circle.lefthalf.filled.inverse")
                    }
                    RecipeSlider(title: "Normal strength", symbol: "cube.transparent",
                                 value: $store.recipe.normalStrength,
                                 range: MaterialRecipe.normalStrengthRange, step: 0.1, format: "%.1f×")
                    Toggle(isOn: $store.recipe.bentNormal) {
                        Label("Bent normal map", systemImage: "arrow.turn.up.right")
                    }
                } header: {
                    Text("Relief")
                } footer: {
                    Text("Height, normals and AO are estimates inferred from color, not measured geometry.")
                }

                Section("Surface") {
                    RecipeSlider(title: "Roughness", symbol: "circle.dotted", value: $store.recipe.roughnessBase,
                                 range: 0...1, step: 0.01)
                    RecipeSlider(title: "Roughness variation", symbol: "waveform.path",
                                 value: $store.recipe.roughnessVariation,
                                 range: MaterialRecipe.roughnessVariationRange, step: 0.01)
                    Toggle(isOn: Binding(get: { store.recipe.assignedMetalness != nil },
                                         set: { store.recipe.assignedMetalness = $0 ? 1 : nil })) {
                        Label("Assign metalness (ORM)", systemImage: "square.stack.3d.up")
                    }
                    if store.recipe.assignedMetalness != nil {
                        RecipeSlider(title: "Metalness", symbol: "gearshape",
                                     value: Binding(get: { store.recipe.assignedMetalness ?? 0 },
                                                    set: { store.recipe.assignedMetalness = $0 }),
                                     range: 0...1, step: 0.01)
                    }
                }

                Section {
                    RecipeSlider(title: "Remove lighting", symbol: "sun.max.trianglebadge.exclamationmark",
                                 value: $store.recipe.albedoEqualize,
                                 range: MaterialRecipe.albedoEqualizeRange, step: 0.01, format: "%.0f%%", percent: true)
                    RecipeSlider(title: "AO strength", symbol: "circle.lefthalf.filled",
                                 value: $store.recipe.aoStrength,
                                 range: MaterialRecipe.aoStrengthRange, step: 0.05, format: "%.2f×")
                    RecipeSlider(title: "AO radius", symbol: "circle.dashed",
                                 value: $store.recipe.aoRadiusPixels,
                                 range: MaterialRecipe.aoRadiusRange, step: 1, format: "%.0f px")
                    RecipeSlider(title: "Make seamless", symbol: "square.grid.3x3",
                                 value: $store.recipe.seamlessBlend,
                                 range: MaterialRecipe.seamlessBlendRange, step: 0.01, format: "%.0f%%", percent: true)
                    Toggle(isOn: $store.recipe.tileWrap) {
                        Label("Wrap filters at edges", systemImage: "arrow.left.and.right.square")
                    }
                } header: {
                    Text("Lighting & Tiling")
                } footer: {
                    Text("Remove lighting evens out low-frequency shading in the photo. Make seamless cross-fades opposite edges so the material tiles; check the Tiled preview.")
                }

                Section {
                    Picker(selection: $store.recipe.normalYDown) {
                        Text("OpenGL  +Y").tag(false)
                        Text("DirectX  −Y").tag(true)
                    } label: {
                        Label("Normal map", systemImage: "arrow.up.and.down")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("normal-convention")
                } header: {
                    Text("Export")
                } footer: {
                    Text(store.recipe.normalYDown
                         ? "Green-down normals for Unreal Engine and DirectX tools."
                         : "Green-up normals for glTF, Blender, Unity, Godot and RealityKit.")
                }
            }
            .navigationTitle("Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.isUpdatingPreview {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Updating preview")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("recipe-done")
                }
            }
        }
    }
}

struct RecipeSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.01
    var format = "%.2f"
    var percent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    private var display: String { String(format: format, percent ? value * 100 : value) }
}

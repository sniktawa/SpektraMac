import SpektraEngine
import SwiftUI

// MARK: - Settings

/// The steps of the process the settings are in, one at a time, chosen in the toolbar over the
/// panel: the camera's exposure, the film, and the print made from it; and the saved presets.
enum SettingsCategory: String, CaseIterable {
    case camera = "Camera", film = "Film", print = "Print", crop = "Crop", presets = "Presets"
}

/// The settings of one step of the process, laid out as Photos' Adjust panel: a group per effect.
struct SettingsPanel: View {
    @Environment(PhotoModel.self) private var model
    let category: SettingsCategory

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                switch category {
                case .camera:
                    AdjustmentGroup("Exposure", systemImage: "plusminus.circle", adjustment: .exposure) {
                        ExposureStrip()
                    } options: {
                        ValueSlider("Exposure", value: $model.exposureEV, in: model.exposureRange, step: 0.1, neutral: 0,
                                    format: ExposureStrip.stops, unit: "EV")
                            .disabled(model.photo == nil)
                        ValueSlider("Highlight boost", value: $model.controls.highlightBoost, in: Controls.range(\.highlightBoost), step: 0.5,
                                    format: .number.precision(.fractionLength(1)), unit: "EV")
                            .help("Raises the brightest highlights before they reach the film, rebuilding light the camera clipped, so bright lights glow more.")
                    }
                    DiffusionGroup(title: "Lens diffusion", adjustment: .cameraDiffusion, filter: \.cameraDiffusion)
                case .film:
                    ChoiceRow(title: "Film", sections: stockSections(model.films), selection: $model.film,
                              controls: $model.controls, choosing: model.controls(choosing:))
                    AdjustmentGroup("Halation", systemImage: "sun.haze", adjustment: .halation,
                                    isOn: $model.controls.halation) {
                        ValueSlider("Strength", value: $model.controls.halationAmount, in: Controls.range(\.halationAmount), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("The glow from light bouncing back off the film base, over the film's own.")
                    } options: {
                        ValueSlider("Size", value: $model.controls.halationSize, in: Controls.range(\.halationSize), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How far the glow reaches, over the film's own.")
                        ValueSlider("Scatter", value: $model.controls.scatterAmount, in: Controls.range(\.scatterAmount), step: 0.05,
                                    format: .number.precision(.fractionLength(2)))
                            .help("Light spreading inside the emulsion, which softens fine detail.")
                        ValueSlider("Scatter size", value: $model.controls.scatterSize, in: Controls.range(\.scatterSize), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How far light spreads inside the emulsion, over the film's own.")
                    }
                    AdjustmentGroup("Couplers", systemImage: "drop.halffull", adjustment: .couplers,
                                    isOn: $model.controls.couplers) {
                        ThumbnailStrip("Saturation", value: $model.controls.couplerSaturation,
                                       in: model.range(of: .couplerSaturation), step: 0.05,
                                       format: .number.precision(.fractionLength(2)), frames: model.strips[.couplerSaturation])
                            .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
                    } options: {
                        ValueSlider("Saturation", value: $model.controls.couplerSaturation,
                                    in: model.range(of: .couplerSaturation), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
                        ValueSlider("Edge contrast", value: $model.controls.couplerEdgeContrast, in: Controls.range(\.couplerEdgeContrast), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How strongly each layer holds back its own development nearby: more gives crisper edges in fine detail. The overall contrast stays the film's.")
                    }
                    AdjustmentGroup("Grain", systemImage: "aqi.medium", adjustment: .grain, isOn: $model.controls.grain) {
                        ValueSlider("Size", value: $model.controls.grainSize, in: Controls.range(\.grainSize), step: 0.05,
                                    format: .number.precision(.fractionLength(2)), unit: "µm²")
                            .help("The area of one silver halide particle: about 0.1 µm² for ISO 100, 0.4 µm² for ISO 400.")
                    } options: {
                        ValueSlider("Softness", value: $model.controls.grainSoftness, in: Controls.range(\.grainSoftness), step: 0.05,
                                    format: .number.precision(.fractionLength(2)), unit: "px")
                            .help("The blur over the grain, in pixels of the render.")
                    }
                case .presets, .crop:
                    // Shown in place of this panel (``PresetsPanel``, ``CropPanel``).
                    EmptyView()
                case .print:
                    if model.controls.scanFilm {
                        Text(model.isSlideFilm
                             ? "A slide is viewed directly, so there's no print."
                             : "The film itself is showing. These settings apply when the toolbar shows Print.")
                            .foregroundStyle(.secondary)
                    }
                    Group {
                        ChoiceRow(title: "Paper", sections: stockSections(model.papers), selection: $model.controls.paper,
                                  controls: $model.controls) { paper in
                            var controls = model.controls
                            controls.paper = paper
                            return controls
                        }
                        AdjustmentGroup("Contrast", systemImage: "circle.lefthalf.filled", adjustment: .contrast) {
                            ToneGraphView()
                        } options: {
                            ValueSlider("Contrast", value: $model.controls.printContrast, in: Controls.range(\.printContrast),
                                        step: 0.05, neutral: 1, format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast around mid-grey: lower brings a bright sky and dark faces closer together.")
                            ValueSlider("Highlight contrast", value: $model.controls.printHighlightContrast,
                                        in: Controls.range(\.printHighlightContrast), step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the light tones alone: lower keeps more detail in a bright sky.")
                            ValueSlider("Shadow contrast", value: $model.controls.printShadowContrast,
                                        in: Controls.range(\.printShadowContrast), step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the dark tones alone: lower opens up faces in shadow.")
                        }
                        AdjustmentGroup("Enlarger", systemImage: "lightbulb", adjustment: .enlarger) {
                            ThumbnailStrip("Print exposure", value: $model.controls.printExposure,
                                           in: model.range(of: .printExposure), step: 0.02,
                                           format: .number.precision(.fractionLength(2)), frames: model.strips[.printExposure])
                        } options: {
                            ValueSlider("Print exposure", value: $model.controls.printExposure, in: model.range(of: .printExposure),
                                        step: 0.02, neutral: 1, format: .number.precision(.fractionLength(2)))
                            ValueSlider("Y filter shift", value: $model.controls.yFilterShift, in: Controls.range(\.yFilterShift), step: 1, neutral: 0,
                                        format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                        unit: "CC")
                            ValueSlider("M filter shift", value: $model.controls.mFilterShift, in: Controls.range(\.mFilterShift), step: 1, neutral: 0,
                                        format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                        unit: "CC")
                            ValueSlider("Preflash", value: $model.controls.preflash, in: Controls.range(\.preflash), step: 0.001,
                                        format: .number.precision(.fractionLength(3)))
                                .help("A flash of plain light on the paper before the print, so light tones such as a bright sky gain some tone. It darkens the whole print: lower the print exposure to bring the mid-tones back.")
                            ValueSlider("Preflash Y tint", value: $model.controls.preflashYFilterShift,
                                        in: Controls.range(\.preflashYFilterShift), step: 1, neutral: 0,
                                        format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                        unit: "CC")
                                .help("The yellow filter for the preflash alone, away from the print's: more tints the light tones blue, less yellow.")
                                .disabled(model.controls.preflash == 0)
                            ValueSlider("Preflash M tint", value: $model.controls.preflashMFilterShift,
                                        in: Controls.range(\.preflashMFilterShift), step: 1, neutral: 0,
                                        format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                        unit: "CC")
                                .help("The magenta filter for the preflash alone, away from the print's: more tints the light tones green, less magenta.")
                                .disabled(model.controls.preflash == 0)
                        }
                        AdjustmentGroup("Vignette", systemImage: "circle.dashed", adjustment: .vignette,
                                        isOn: $model.controls.vignette) {
                            ValueSlider("Strength", value: $model.controls.vignetteStops, in: Controls.range(\.vignetteStops),
                                        step: 0.1, neutral: 0,
                                        format: .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)),
                                        unit: "EV")
                                .help("Burning the print's edges in (more) as a darkroom printer does, or holding them back for a reverse vignette (less), which lightens them.")
                        } options: {
                            ValueSlider("Midpoint", value: $model.controls.vignetteMidpoint, in: Controls.range(\.vignetteMidpoint),
                                        step: 0.01, format: .number.precision(.fractionLength(2)))
                                .help("How far out from the centre the vignette is half done: 1 is at the corners.")
                            ValueSlider("Softness", value: $model.controls.vignetteSoftness, in: Controls.range(\.vignetteSoftness),
                                        step: 0.01, format: .number.precision(.fractionLength(2)))
                                .help("How gradually the vignette fades in: as a hand or card moved during the exposure.")
                        }
                        AdjustmentGroup("Burn", systemImage: "sun.horizon", adjustment: .burn, isOn: $model.controls.burn) {
                            ValueSlider("Strength", value: $model.controls.burnStops, in: Controls.range(\.burnStops), step: 0.1,
                                        format: .number.precision(.fractionLength(1)), unit: "EV") {
                                model.isAdjustingBurn = $0
                            }
                            .help("Extra enlarger exposure where the photo is bright, as a darkroom printer burns in a sky: a pale sky darkens and gets its colour back, and the rest of the print stays as it is.")
                            ValueSlider("Threshold", value: $model.controls.burnThreshold, in: Controls.range(\.burnThreshold),
                                        step: 0.1, format: ExposureStrip.stops, unit: "EV") {
                                model.isAdjustingBurn = $0
                            }
                            .help("How bright a part of the photo must be to burn, in stops over mid-grey. About +2.5 is where a screen's white sits; lower takes in more. Holding a Burn slider shows what burns, white on black.")
                        }
                        DiffusionGroup(title: "Enlarger diffusion", adjustment: .enlargerDiffusion,
                                       filter: \.enlargerDiffusion)
                        AdjustmentGroup("Glare", systemImage: "sun.max", adjustment: .glare, isOn: $model.controls.glare) {
                            ValueSlider("Amount", value: $model.controls.glareAmount, in: Controls.range(\.glareAmount), step: 0.01,
                                        format: .number.precision(.fractionLength(2)), unit: "%")
                                .help("Stray light over the print as it's viewed, in percent of the light: it lifts the blacks.")
                        } options: {
                            ValueSlider("Roughness", value: $model.controls.glareRoughness, in: Controls.range(\.glareRoughness), step: 0.05,
                                        format: .number.precision(.fractionLength(2)))
                                .help("How unevenly the stray light falls.")
                            ValueSlider("Softness", value: $model.controls.glareSoftness, in: Controls.range(\.glareSoftness), step: 0.1,
                                        format: .number.precision(.fractionLength(1)), unit: "px")
                                .help("The blur over the stray light, in pixels of the render.")
                        }
                    }
                    .disabled(model.controls.scanFilm)
                    AdjustmentGroup("Scanned print", systemImage: "scanner", adjustment: .scanLook,
                                    isOn: $model.controls.scanLook) {
                        ValueSlider("Shadow colour", value: $model.controls.scanShadowAmount, in: Controls.range(\.scanShadowAmount),
                                    step: 0.01, format: .number.precision(.fractionLength(2)))
                            .help("How far the shadows are pushed towards the colour below, as a flatbed scan of a print tints them.")
                        ValueSlider("Hue", value: $model.controls.scanShadowHue, in: Controls.range(\.scanShadowHue),
                                    step: 1, format: .number.precision(.fractionLength(0)), unit: "°")
                            .help("The shadows' colour: 0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta.")
                    } options: {
                        ValueSlider("Black level", value: $model.controls.scanBlackLevel, in: Controls.range(\.scanBlackLevel),
                                    step: 0.001, format: .number.precision(.fractionLength(3)))
                            .help("How far the blacks are lifted, as a scanner sees a print's deepest black as a dark grey. It takes the shadows' colour.")
                        ValueSlider("Shadow range", value: $model.controls.scanShadowRange, in: Controls.range(\.scanShadowRange),
                                    step: 0.01, format: .number.precision(.fractionLength(2)))
                            .help("How far up the tones the shadow colour reaches.")
                    }
                }
            }
            .padding(.vertical)
            .padding(.leading, 15)
            .padding(.trailing, 20)
        }
    }
}

/// A group of settings as Photos lays out an adjustment: a disclosure headed by its symbol and
/// name, a reset arrow and, where the effect can be off, an on/off circle; its main control, then
/// the rest under Options, if it has any. Whether each is open is kept with the window. Sizes and
/// shades measured from Photos' (macOS 26) screenshots.
private struct AdjustmentGroup<Main: View, Options: View>: View {
    @Environment(PhotoModel.self) private var model
    let title: String
    let systemImage: String
    let adjustment: Controls.Adjustment
    let isOn: Binding<Bool>?
    let main: Main
    let options: Options
    @SceneStorage private var isExpanded: Bool
    @SceneStorage private var showsOptions: Bool

    init(_ title: String, systemImage: String, adjustment: Controls.Adjustment, isOn: Binding<Bool>? = nil,
         @ViewBuilder main: () -> Main, @ViewBuilder options: () -> Options) {
        self.title = title
        self.systemImage = systemImage
        self.adjustment = adjustment
        self.isOn = isOn
        self.main = main()
        self.options = options()
        _isExpanded = SceneStorage(wrappedValue: true, "adjustment.\(adjustment)")
        _showsOptions = SceneStorage(wrappedValue: false, "adjustment.\(adjustment).options")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                main
                if Options.self != EmptyView.self {
                    DisclosureGroup(isExpanded: $showsOptions) {
                        VStack(spacing: 6) { options }
                            .padding(.top, 7)
                            .padding(.bottom, 14)
                    } label: {
                        Button("Options") {
                            withAnimation(.snappy) { showsOptions.toggle() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(title) options")
                        .accessibilityValue(showsOptions ? "Expanded" : "Collapsed")
                    }
                    .disclosureGroupStyle(PhotosDisclosureStyle(contentIndent: 0))
                }
            }
            .padding(.top, 6)
            .disabled(isOn?.wrappedValue == false)
        } label: {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text(title)
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                // Borderless draws it grey and greys it further when disabled; a foreground style
                // over it, inherited or set, would hold it at one shade.
                Button("Reset \(title)", systemImage: "arrow.uturn.backward") { model.reset(adjustment) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .disabled(model.isAtDefaults(adjustment))
                    .help("Back to the film's defaults")
                if let isOn {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(CircleToggleStyle())
                        .help(isOn.wrappedValue ? "Turn off" : "Turn on")
                }
            }
        }
        .disclosureGroupStyle(PhotosDisclosureStyle(contentIndent: 14))
    }
}

extension AdjustmentGroup where Options == EmptyView {
    /// A group whose controls all show at once, with no Options.
    init(_ title: String, systemImage: String, adjustment: Controls.Adjustment, isOn: Binding<Bool>? = nil,
         @ViewBuilder main: () -> Main) {
        self.init(title, systemImage: systemImage, adjustment: adjustment, isOn: isOn, main: main) { EmptyView() }
    }
}

/// Photos' disclosure: a small grey chevron before the label that turns as it opens, and the
/// content under it, indented by `contentIndent`. The label is a button that opens it too, named
/// with the disclosure and whether it's open, so VoiceOver and the keyboard have that and the
/// chevron is for the pointer alone. A group (indented) closed has a line under it, from its symbol.
private struct PhotosDisclosureStyle: DisclosureGroupStyle {
    let contentIndent: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 22, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.snappy) { configuration.isExpanded.toggle() }
                    }
                    .accessibilityHidden(true)
                configuration.label
            }
            .frame(minHeight: 22)
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, contentIndent)
            } else if contentIndent > 0 {
                Divider()
                    .padding(.leading, 15)
            }
        }
    }
}

/// Photos' on/off circle for an adjustment: a ring when it's off, a check when it's on.
private struct CircleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The Film or Paper row, or a diffusion filter's: its choices in a pop-up menu (``ChoiceMenu``).
/// A row of its own, as `LabeledContent` gives its content at most about half the row, cutting
/// short names.
private struct ChoiceRow<Value: Hashable>: View {
    let title: String
    let sections: [ChoiceMenu<Value>.Section]
    @Binding var selection: Value
    @Binding var controls: Controls
    /// What choosing a value sets the controls to.
    let choosing: (Value) -> Controls

    var body: some View {
        HStack {
            Text(title)
                .fixedSize()
            Spacer(minLength: 8)
            ChoiceMenu(sections: sections, selection: $selection, controls: $controls, choosing: choosing)
                .layoutPriority(1)
                .accessibilityLabel(title)
        }
    }
}

/// Stocks under headings, from their profiles: slides, still negatives or papers, then cine stocks.
private func stockSections(_ stocks: [ProfileInfo]) -> [ChoiceMenu<String>.Section] {
    let groups = Dictionary(grouping: stocks) { stock -> String in
        if stock.type == .positive { return "Slide" }
        if stock.use == .cine { return "Cine" }
        return stock.stage == .filming ? "Negative" : "Still"
    }
    return ["Slide", "Negative", "Still", "Cine"].compactMap { heading in
        groups[heading].map { ChoiceMenu.Section(heading: heading, choices: $0.map { ($0.name, $0.stock) }) }
    }
}

/// A pop-up menu of choices, under headings where they have them. While it's open, the photo
/// shows the choice the pointer is on as choosing it would, and goes back to `controls` as they
/// were if the menu closes without a choice. As it opens, the model renders each choice's finished
/// look, nearest the current one first (``PhotoModel/preload(_:)``), so the pointer finds it ready.
/// AppKit's pop-up button: SwiftUI's menus don't say which item is highlighted, and an
/// `NSMenuDelegate` is told.
private struct ChoiceMenu<Value: Hashable>: NSViewRepresentable {
    struct Section {
        let heading: String?
        let choices: [(name: String, value: Value)]
    }

    @Environment(PhotoModel.self) private var model
    let sections: [Section]
    @Binding var selection: Value
    /// What choosing a value may change, as the menu found it.
    @Binding var controls: Controls
    /// What choosing a value sets the controls to.
    let choosing: (Value) -> Controls

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // As SwiftUI's picker: the name at the arrows, cut short where the row is narrow.
        button.alignment = .right
        (button.cell as! NSPopUpButtonCell).lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let values = sections.flatMap { $0.choices.map(\.value) }
        if coordinator.values != values {
            coordinator.values = values
            coordinator.measured = nil
            button.menu = menu(delegate: coordinator)
        }
        // While the menu is open, its check mark stays on the choice it opened with.
        if !coordinator.isOpen {
            button.select(button.itemArray.first { $0.representedObject as? Value == selection })
        }
        button.isEnabled = context.environment.isEnabled
    }

    /// The selected choice's width, as SwiftUI's picker has, rather than the widest choice's: the
    /// pop-up button sizes itself (`intrinsicContentSize`, its cell's `cellSize`) only to its
    /// widest item. Measured once per list of choices and selected choice and kept: each step of
    /// a slider lays out the panel again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        let selected = button.titleOfSelectedItem ?? ""
        if coordinator.measured?.selected != selected {
            let widest = button.intrinsicContentSize
            func width(_ title: String) -> CGFloat { (title as NSString).size(withAttributes: [.font: button.font!]).width }
            let ideal = widest.width - (button.itemTitles.map(width).max() ?? 0) + width(selected)
            coordinator.measured = (selected, CGSize(width: ideal, height: widest.height))
        }
        let ideal = coordinator.measured!.size
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func menu(delegate: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = delegate
        for section in sections {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            if let heading = section.heading {
                menu.addItem(.sectionHeader(title: heading))
            }
            for choice in section.choices {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.representedObject = choice.value
                menu.addItem(item)
            }
        }
        return menu
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: ChoiceMenu
        /// The values the menu lists.
        var values: [Value] = []
        /// The button's size for the choice it shows (``sizeThatFits(_:nsView:context:)``), until
        /// the menu lists other choices.
        var measured: (selected: String, size: CGSize)?
        /// The controls the menu opened with, while it's open.
        private var opened: Controls?
        private var chosen: Value?
        var isOpen: Bool { opened != nil }

        init(parent: ChoiceMenu) {
            self.parent = parent
        }

        func menuWillOpen(_ menu: NSMenu) {
            opened = parent.controls
            chosen = nil
            // What the pointer shows and what's chosen undo in one step.
            parent.model.beginChange()
            // Outward from the current choice, as the pointer moves from it.
            let order = menu.items.compactMap { $0.representedObject as? Value }
            let current = order.firstIndex(of: parent.selection) ?? 0
            let nearestFirst = order.indices.sorted { (abs($0 - current), $0) < (abs($1 - current), $1) }
            parent.model.preload(nearestFirst.map { parent.choosing(order[$0]) })
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let opened else { return }
            show(item?.representedObject as? Value, from: opened)
        }

        @objc func choose(_ button: NSPopUpButton) {
            chosen = button.selectedItem?.representedObject as? Value
        }

        func menuDidClose(_ menu: NSMenu) {
            parent.model.stopPreloading()
            // The pop-up sends its action as the menu closes: settle once both have run.
            DispatchQueue.main.async { [self] in
                guard let opened else { return }
                self.opened = nil
                show(chosen, from: opened)
                parent.model.endChange()
            }
        }

        /// The controls the menu opened with, `value` chosen from them unless it's theirs.
        private func show(_ value: Value?, from opened: Controls) {
            parent.controls = opened
            if let value, value != parent.selection {
                parent.selection = value
            }
        }
    }
}

/// The exposure, in stops over the photo as shot. Its dots are where each way of metering puts
/// it for this photo (``MeteringMark``); a mark's name shows only while the exposure is on it, so
/// marks a fraction of a stop apart don't crowd, and the trackpad clicks as it lands on one.
struct ExposureStrip: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let readings = model.photo.map { photo in
            MeteringMark.allCases.compactMap { mark in photo.metering.ev[mark.rawValue].map { (mark: mark, ev: $0) } }
        } ?? []
        // One dot for marks that meter the same.
        let marks = Dictionary(grouping: readings) { $0.ev }
            .map { ev, readings in (name: readings.map(\.mark.name).formatted(.list(type: .and)), value: ev) }
            .sorted { $0.value < $1.value }
        let here = model.marksAtExposure
        let range = model.exposureRange
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailStrip("Exposure", value: $model.exposureEV, in: range, step: 0.1, format: Self.stops, unit: "EV",
                           frames: model.strips[.exposure], marks: marks) {
                model.isAdjustingExposure = $0
            }
            .sensoryFeedback(.alignment, trigger: here) { _, new in model.isAdjustingExposure && !new.isEmpty }
            MarkName(name: here.map(\.name).formatted(.list(type: .and)),
                     fraction: (model.exposureEV - range.lowerBound) / (range.upperBound - range.lowerBound))
            Text(description(here: here))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.photo == nil)
    }

    static let stops = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        .sign(strategy: .always(includingZero: false))

    /// What the mark the exposure is on meters, or how far it is from the nearest one.
    private func description(here: [MeteringMark]) -> String {
        guard let photo = model.photo else {
            return "\(model.controls.exposureMark.name): \(model.controls.exposureMark.about)."
        }
        let resolved = photo.metering.reading(resolving: model.controls.exposureMark).mark
        var text = if let mark = here.first(where: { $0 == resolved }) ?? here.first {
            "\(mark.name): \(mark.about)."
        } else {
            "\(model.controls.exposureOffsetEV.formatted(Self.stops)) EV from \(resolved.name)."
        }
        if resolved != model.controls.exposureMark {
            text += " No \(model.controls.exposureMark.name.lowercased()) found in this photo, so it starts from \(resolved.name)."
        }
        return text
    }
}

/// The name of the mark the exposure is on, under its dot on the strip, kept inside the row at
/// the ends.
private struct MarkName: View {
    let name: String
    /// Where the dot is along the strip, 0 at its minimum.
    let fraction: Double
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let x = fraction * geometry.size.width
            Text(name)
                .foregroundStyle(.tint)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .position(x: min(max(x, width / 2), geometry.size.width - width / 2), y: geometry.size.height / 2)
        }
        .frame(height: 16)
    }
}

private extension MeteringMark {
    var name: String {
        switch self {
        case .asShot: "As shot"
        case .centreWeighted: "Centre-weighted"
        case .objects: "Objects"
        case .people: "People"
        case .faces: "Faces"
        }
    }

    /// What the mark's exposure is.
    var about: String {
        switch self {
        case .asShot: "the exposure the camera chose"
        case .centreWeighted: "meters the whole frame, the centre counting most, as Spektrafilm and a film camera do"
        case .objects: "meters what stands out in the frame"
        case .people: "meters the people in the frame, so a bright sky or background can't darken them"
        case .faces: "meters the faces in the frame"
        }
    }
}

/// A diffusion filter on the camera's lens or the enlarger's: the filter and its strength, with its
/// glow's size and warmth under Options, each the controls at its key path.
private struct DiffusionGroup: View {
    @Environment(PhotoModel.self) private var model
    let title: String
    let adjustment: Controls.Adjustment
    let filter: WritableKeyPath<Controls, Parameters.DiffusionFilter>

    var body: some View {
        @Bindable var model = model
        let settings = $model.controls[dynamicMember: filter]
        AdjustmentGroup(title, systemImage: "camera.filters", adjustment: adjustment, isOn: settings.active) {
            ChoiceRow(title: "Filter",
                      sections: [.init(heading: nil, choices: Parameters.DiffusionFilter.Family.allCases.map { ($0.name, $0) })],
                      selection: settings.filterFamily, controls: $model.controls) { choice in
                var choosing = model.controls
                choosing[keyPath: filter].filterFamily = choice
                return choosing
            }
            .help("Glimmerglass keeps detail and glows faintly; Black Pro-Mist gives a tight, punchy halo; Pro-Mist a broader pastel haze; CineBloom a wide glow that lifts the whole frame.")
            ValueSlider("Strength", value: settings.strength, in: range(\.strength), step: 0.125,
                        format: .number.precision(.fractionLength(0...3)))
                .help("The filter's grade, as filters are sold: 1/8, 1/4, 1/2, 1 and 2. Stronger spreads more of the light into the glow.")
        } options: {
            ValueSlider("Size", value: settings.spatialScale, in: range(\.spatialScale), step: 0.05, neutral: 1,
                        format: .number.precision(.fractionLength(2)))
                .help("How far the glow reaches, over the filter's own.")
            ValueSlider("Warmth", value: settings.haloWarmth, in: range(\.haloWarmth), step: 0.05, neutral: 0,
                        format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                .help("Warmer light at the glow's outer rim and cooler at its centre, over the filter's own; below 0, the reverse.")
        }
    }

    /// The range of one of this filter's settings (``Controls/ranges``).
    private func range(_ setting: WritableKeyPath<Parameters.DiffusionFilter, Double>) -> ClosedRange<Double> {
        Controls.range(filter.appending(path: setting))
    }
}

extension Parameters.DiffusionFilter.Family {
    var name: String {
        switch self {
        case .glimmerglass: "Glimmerglass"
        case .blackProMist: "Black Pro-Mist"
        case .proMist: "Pro-Mist"
        case .cinebloom: "CineBloom"
        }
    }
}

/// A slider as Photos draws its adjustments: the name and value inside a bar that fills from
/// `neutral` (the lower bound unless given) to the value; under the pointer, a ruler along its top
/// and the value's line in the accent colour. Dragging anywhere on it moves the value
/// from where it was, the bar's width for the whole range; with Full Keyboard Access the arrow
/// keys step it. With Increase Contrast, the fill and the line are stronger. SwiftUI's `Slider`
/// can't be restyled (there's no slider style to conform to), so the bar is drawn here, with the
/// system slider standing in for VoiceOver, reading the value as the bar shows it.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let neutral: Double?
    let format: FloatingPointFormatStyle<Double>
    let unit: String
    let onEditingChanged: (Bool) -> Void
    @State private var width: CGFloat = 0
    /// The value when the drag began.
    @State private var dragStart: Double?
    @State private var isHovered = false
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, neutral: Double? = nil,
         format: FloatingPointFormatStyle<Double>, unit: String = "", onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.neutral = neutral
        self.format = format
        self.unit = unit
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        // Sizes and shades measured from Photos' (macOS 26) screenshots. Shades the system has are its
        // own (the measured text is `.secondary` in dark mode); the rest as the primary style's opacity.
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(valueText)
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            let x = range.fraction(of: value) * width, origin = range.fraction(of: neutral ?? range.lowerBound) * width
            let isActive = isHovered || dragStart != nil
            ZStack(alignment: .leading) {
                Rectangle().fill(.quinary)
                Rectangle().fill(.primary.opacity(contrast == .increased ? 0.35 : 0.19))
                    .frame(width: abs(x - origin))
                    .offset(x: min(x, origin))
                Rectangle().fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(contrast == .increased ? 0.6 : 0.22)))
                    .frame(width: 3)
                    .offset(x: min(max(x - 1.5, 0), width - 3))
                if isActive {
                    // Photos' ruler, over the line: a hairline every 6 pt either side of the neutral
                    // value, every fifth longer and every tenth brighter.
                    Canvas { context, size in
                        let hairline = 1 / displayScale
                        for tick in -Int(origin / 6)...Int((size.width - origin) / 6) {
                            let tickX = ((origin + CGFloat(tick) * 6) * displayScale).rounded() / displayScale
                            context.fill(Path(CGRect(x: tickX, y: 0, width: hairline, height: tick % 5 == 0 ? 5 : 3)),
                                         with: .style(tick % 10 == 0 ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary)))
                        }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 5))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if dragStart == nil {
                    model.isAdjusting = true
                    onEditingChanged(true)
                }
                let start = dragStart ?? value
                dragStart = start
                guard width > 0 else { return }
                value = range.stepped(start + drag.translation.width / width * (range.upperBound - range.lowerBound), by: step)
            }
            .onEnded { _ in endDrag() })
        // A drag cut off as the slider goes (its window closed, say) never ends otherwise.
        .onDisappear {
            if dragStart != nil {
                endDrag()
            }
        }
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left: value = range.stepped(value - step, by: step)
            case .right: value = range.stepped(value + step, by: step)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(title) }
                .accessibilityValue(valueText)
        }
    }

    private var valueText: String {
        unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)"
    }

    private func endDrag() {
        dragStart = nil
        model.isAdjusting = false
        onEditingChanged(false)
    }
}

/// A control as Photos shows its main adjustments: frames of the photo across its range
/// (``Controls/Strip``), with a line at the value; `marks` are dots under it. As in Photos, the
/// value itself shows on the control's bar under Options. Clicking or dragging along it sets the
/// value there; with Full Keyboard Access the arrow keys step it, and the system slider stands in
/// for VoiceOver, reading the value in `format` and `unit`, with an action to go to each mark.
/// Drawn here, as Photos' strip isn't one of SwiftUI's or AppKit's controls.
private struct ThumbnailStrip: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: FloatingPointFormatStyle<Double>
    let unit: String
    /// None until the model has made them.
    let frames: [CGImage]?
    let marks: [(name: String, value: Double)]
    let onEditingChanged: (Bool) -> Void
    @State private var width: CGFloat = 0
    @State private var isDragging = false
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         format: FloatingPointFormatStyle<Double>, unit: String = "", frames: [CGImage]?,
         marks: [(name: String, value: Double)] = [], onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.unit = unit
        self.frames = frames
        self.marks = marks
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                if let frames {
                    ForEach(frames.indices, id: \.self) { index in
                        Color.clear
                            .overlay { Image(decorative: frames[index], scale: 1).resizable().scaledToFill() }
                            .clipped()
                    }
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 38)
            .overlay(alignment: .leading) {
                Rectangle().fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: min(max(range.fraction(of: value) * width - 1, 0), width - 2))
            }
            .clipShape(.rect(cornerRadius: 5))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        model.isAdjusting = true
                        onEditingChanged(true)
                    }
                    guard width > 0 else { return }
                    value = range.stepped(range.lowerBound + drag.location.x / width * (range.upperBound - range.lowerBound), by: step)
                }
                .onEnded { _ in endDrag() })
            // A drag cut off as the strip goes (its window closed, say) never ends otherwise.
            .onDisappear {
                if isDragging {
                    endDrag()
                }
            }
            if !marks.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(marks, id: \.value) { mark in
                        Circle().fill(.secondary)
                            .frame(width: 4, height: 4)
                            .offset(x: range.fraction(of: mark.value) * width - 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4, alignment: .leading)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left: value = range.stepped(value - step, by: step)
            case .right: value = range.stepped(value + step, by: step)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(title) }
                .accessibilityValue(unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)")
                .accessibilityActions {
                    ForEach(marks, id: \.value) { mark in
                        Button(mark.name) { value = mark.value }
                    }
                }
        }
    }

    private func endDrag() {
        isDragging = false
        model.isAdjusting = false
        onEditingChanged(false)
    }
}

extension ClosedRange<Double> {
    /// Where `value` lies along the range: 0 at its lower bound, 1 at its upper.
    func fraction(of value: Double) -> Double {
        (value - lowerBound) / (upperBound - lowerBound)
    }

    /// `value` at the nearest `step` from the lower bound, within the range: what a slider sets.
    func stepped(_ value: Double, by step: Double) -> Double {
        let stepped = lowerBound + ((value - lowerBound) / step).rounded() * step
        return Swift.min(Swift.max(stepped, lowerBound), upperBound)
    }
}

import SwiftUI

/// Mac pixels the cursor moves per point of finger travel at 1× sensitivity.
private let baseGain = 1.1
/// Mac scroll pixels per unit of Crown turn at 1× sensitivity.
/// Deliberately low: the Crown produces far more counts per detent than a finger does, so even 1× felt fast.
private let crownPixels = 50.0
/// Touch area the pad leaves alone so the system toolbar button always gets its taps.
private let menuZone: CGFloat = 54

/// Black pad, one system toolbar button in the top-left, everything else behind that button.
struct ContentView: View {
    @StateObject private var pointer = Pointer()
    @State private var crown = 0.0
    @FocusState private var crownFocused: Bool
    @State private var menuOpen = false
    // New keys so the 0.1 starting value applies to installs that already saved the old 1.0.
    @AppStorage("padSensitivityV2") private var sensitivity = 0.1
    @AppStorage("crownSensitivityV2") private var crownSensitivity = 0.1
    @AppStorage("holdSeconds") private var holdSeconds = 1.0
    @AppStorage("scrollMode") private var scrollMode = 0   // 0 = 顺滑, 1 = 硬停
    @AppStorage("crownInverted") private var crownInverted = false
    @AppStorage("smoothMs") private var smoothMs = 20

    var body: some View {
        NavigationStack {
            pad
        }
        .background(.black)
    }

    /// Kept as its own property: one long modifier chain inside `body` made the type-checker give up.
    private var pad: some View {
        Trackpad(pointer: pointer, sensitivity: sensitivity, holdSeconds: holdSeconds)
            .ignoresSafeArea()
            .focusable()
            .focused($crownFocused)
            .digitalCrownRotation($crown)
            .onChange(of: crown) { old, new in
                let delta = (new - old) * crownPixels * crownSensitivity
                pointer.scroll(by: crownInverted ? -delta : delta)
            }
            .onAppear {
                crownFocused = true
                pointer.setScrollMode(Int16(scrollMode))
                pointer.setSmoothDelay(Int16(smoothMs))
            }
            .onChange(of: scrollMode) { _, mode in pointer.setScrollMode(Int16(mode)) }
            .onChange(of: smoothMs) { _, ms in pointer.setSmoothDelay(Int16(ms)) }
            .onChange(of: pointer.connected) { crownFocused = true }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { menuOpen = true } label: { Image(systemName: "laptopcomputer") }
                }
            }
            .sheet(isPresented: $menuOpen) {
                PadMenu(pointer: pointer,
                        sensitivity: $sensitivity,
                        crownSensitivity: $crownSensitivity,
                        holdSeconds: $holdSeconds,
                        scrollMode: $scrollMode,
                        crownInverted: $crownInverted,
                        smoothMs: $smoothMs)
            }
    }
}

/// The pad: drag to move, tap to click, hold still to grab, Crown to scroll.
private struct Trackpad: View {
    let pointer: Pointer
    let sensitivity: Double
    let holdSeconds: Double

    @State private var pressing = false
    @State private var held = false          // press-and-hold reached its time; a lift now means right click
    @State private var dragging = false
    @State private var holdTimer: Timer?
    @State private var stillEnough = false
    @State private var touchDown: TimeInterval = 0
    @State private var lastTranslation = CGSize.zero
    @State private var travelled = 0.0
    @State private var leftover = CGSize.zero
    @State private var clicks = 0

    /// How far the finger may drift before "press and hold" stops counting as a grab, in points.
    private let stillTolerance: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.black)
            .overlay {
                // Faint press / grab edge, so there is feedback without showing anything on the black pad.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(dragging ? 0.22 : pressing ? 0.12 : 0), lineWidth: 1)
            }
            .animation(.smooth(duration: 0.15), value: pressing)
            .animation(.smooth(duration: 0.2), value: dragging)
            // Leaves the top-left corner to the toolbar button; touches there never reach the pad.
            .contentShape(PadHitArea())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressing {
                            pressing = true
                            travelled = 0
                            stillEnough = true
                            lastTranslation = .zero
                            leftover = .zero
                            touchDown = ProcessInfo.processInfo.systemUptime
                            holdTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { _ in
                                guard stillEnough else { return }
                                held = true               // still nothing sent: lift = right click, move = grab
                                clicks += 1               // drives the haptic below
                            }
                        }
                        let t = value.translation
                        let d = CGSize(width: t.width - lastTranslation.width, height: t.height - lastTranslation.height)
                        lastTranslation = t
                        let distance = (d.width * d.width + d.height * d.height).squareRoot()
                        travelled += distance
                        // Before the hold time: any real movement means this is a plain cursor drag.
                        if !held, stillEnough, travelled > stillTolerance {
                            stillEnough = false
                            holdTimer?.invalidate()
                            holdTimer = nil
                        }
                        // After the hold time: moving starts a grab, staying still keeps it a right click.
                        if held, !dragging, travelled > 3 {
                            dragging = true
                            pointer.send(.drag, 1, at: touchDown)
                        }
                        guard distance > 0.01 else { return }
                        emit(d)
                    }
                    .onEnded { _ in
                        holdTimer?.invalidate()
                        pressing = false
                        lastTranslation = .zero
                        let wasHeld = held
                        held = false
                        if dragging {
                            dragging = false
                            pointer.send(.drag, 0, at: ProcessInfo.processInfo.systemUptime - 0.05) // just before the lift
                        } else if wasHeld {
                            clicks += 1
                            pointer.send(.rightClick, at: touchDown)
                        } else if travelled < 3 {
                            clicks += 1
                            pointer.send(.leftClick, at: touchDown)
                        }
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: clicks)
            .sensoryFeedback(trigger: dragging) { _, now in .impact(weight: now ? .heavy : .light) }
    }

    /// Turns a finger delta into Mac pixels, with a little acceleration so fast swipes cover more ground
    /// while slow ones stay precise. Fractions are carried over so slow, steady drags still add up.
    private func emit(_ d: CGSize) {
        let distance = (d.width * d.width + d.height * d.height).squareRoot()
        // Gentle acceleration only: a fast swipe tops out at ~1.5×, so speed comes from the slider, not from
        // the gesture getting away from you.
        let gain = baseGain * sensitivity * (1 + min(distance / 16, 0.5))
        leftover.width += d.width * gain
        leftover.height += d.height * gain
        let dx = Int16(clamping: Int(leftover.width.rounded(.towardZero)))
        let dy = Int16(clamping: Int(leftover.height.rounded(.towardZero)))
        if dx != 0 { leftover.width -= CGFloat(dx) }
        if dy != 0 { leftover.height -= CGFloat(dy) }
        if dx != 0 || dy != 0 { pointer.move(dx, dy) }
    }
}

/// Full-screen hit area with the top-left corner cut out, so the toolbar button always wins its taps.
private struct PadHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let zone = min(menuZone, min(rect.width, rect.height))
        path.addRect(CGRect(x: rect.minX, y: rect.minY + zone, width: rect.width, height: rect.height - zone))
        path.addRect(CGRect(x: rect.minX + zone, y: rect.minY, width: rect.width - zone, height: zone))
        return path
    }
}

/// Device selection and the three tuning sliders live behind the toolbar button.
private struct PadMenu: View {
    @ObservedObject var pointer: Pointer
    @Binding var sensitivity: Double
    @Binding var crownSensitivity: Double
    @Binding var holdSeconds: Double
    @Binding var scrollMode: Int
    @Binding var crownInverted: Bool
    @Binding var smoothMs: Int
    @Environment(\.dismiss) private var dismiss

    @State private var confirmForget = false
    @State private var forgetTitle = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    macSection
                    tuning
                    if pointer.pairedName != nil { forgetButton }
                    Text("@SycamoresZhang")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }
            .navigationTitle("设置")
            .confirmationDialog(forgetTitle, isPresented: $confirmForget, titleVisibility: .visible) {
                Button("忘记这台 Mac", role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pointer.forget() }
                }
            }
        }
    }

    @ViewBuilder
    private var macSection: some View {
        if pointer.connected {
            row(pointer.pairedName ?? "Mac", detail: "已连接", tint: .green)
        } else if let name = pointer.pairedName {
            row(name, detail: "等待连接…", tint: .orange)
        } else if pointer.found.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                Text("正在搜索附近的 Mac…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            ForEach(pointer.found) { mac in
                Button {
                    pointer.pair(mac)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text(mac.name)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("连接")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white, in: Capsule())
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 52)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tuning: some View {
        VStack(spacing: 6) {
            SliderRow(title: "触控灵敏度",
                      value: String(format: "%.1f×", sensitivity),
                      binding: $sensitivity,
                      range: 0.1...10.0,
                      gradations: 20)
            SliderRow(title: "表冠滚动",
                      value: crownSensitivity < 0.1
                          ? String(format: "%.3f×", crownSensitivity)
                          : String(format: "%.2f×", crownSensitivity),
                      binding: $crownSensitivity,
                      range: 0.006...2.4,
                      gradations: 20,
                      logarithmic: true)
            SliderRow(title: "长按拖拽",
                      value: String(format: "%.1f 秒", holdSeconds),
                      binding: $holdSeconds,
                      range: 0.4...2.0)
            SliderRow(title: "光标平滑",
                      value: smoothMs == 0 ? "直出" : String(format: "%.0f ms", Double(smoothMs)),
                      binding: Binding(
                        get: { Double(smoothMs) },
                        set: { smoothMs = Int($0) }),
                      range: 0...40,
                      gradations: 20)
            scrollModeCard
            invertCard
        }
    }

    /// Two ways to scroll with the Crown; the Mac switches between them on the fly.
    private var scrollModeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("表冠手感")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                modeButton("顺滑", tag: 0, detail: "触控板式")
                modeButton("硬停", tag: 1, detail: "松手立停")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Some people expect the page to move the other way for the same Crown turn.
    private var invertCard: some View {
        HStack(spacing: 8) {
            Text("表冠反转")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Toggle("", isOn: $crownInverted)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func modeButton(_ title: String, tag: Int, detail: String) -> some View {
        Button {
            scrollMode = tag
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(scrollMode == tag ? Color.white : Color(white: 0.24),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(scrollMode == tag ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    private var forgetButton: some View {
        Button {
            forgetTitle = pointer.pairedName ?? "Mac"
            confirmForget = true
        } label: {
            Text("忘记这台 Mac")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func row(_ title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One labelled slider in a card, stepping in 0.1 so the value is easy to read and reproduce.
private struct SliderRow: View {
    let title: String
    let value: String
    @Binding var binding: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var gradations: Int = 0   // >0: the slider moves in that many even steps, whatever the units are
    var logarithmic = false   // >0 gradations + this: steps are equal in ratio, so the middle sits at √(min·max)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if gradations > 0 {
                Slider(value: indexBinding, in: 0...Double(gradations), step: 1)
            } else {
                Slider(value: $binding, in: range, step: step)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Maps the real value onto 0...gradations. Linear by default; geometric when `logarithmic`, so each
    /// step multiplies by the same factor and the middle position is the geometric mean of the range.
    private var indexBinding: Binding<Double> {
        Binding {
            let low = range.lowerBound, high = range.upperBound
            guard high > low else { return 0 }
            if logarithmic {
                guard low > 0 else { return 0 } // geometric steps need a positive base
                return (log(binding / low) / log(high / low) * Double(gradations)).rounded()
            }
            return ((binding - low) / (high - low) * Double(gradations)).rounded()
        } set: { index in
            let low = range.lowerBound, high = range.upperBound
            if logarithmic, low > 0 {
                let value = low * pow(high / low, index / Double(gradations))
                binding = (value * 1000).rounded() / 1000
            } else {
                binding = (low + index / Double(gradations) * (high - low) * 100).rounded() / 100
            }
        }
    }
}

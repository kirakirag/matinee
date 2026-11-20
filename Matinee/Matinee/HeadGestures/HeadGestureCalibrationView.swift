import MatineeKit
import SwiftUI

/// The sheet that teaches Matinee a person's head gestures: the steps along the top, a head and shoulders that mirror
/// theirs, and under the words how far the current step is.
struct HeadGestureCalibrationView: View {
    @Environment(HeadGestureService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var started: Bool
    /// The step on screen: it trails the session by the moment the finished step's tick is shown.
    @State private var shown: CalibrationSession.Step
    @State private var stepDone = false

    /// Opens on the first page; previews start further in.
    init(started: Bool = false, shown: CalibrationSession.Step = .still) {
        _started = State(initialValue: started)
        _shown = State(initialValue: shown)
    }

    private enum Page: Equatable { case intro, denied, waiting, step(CalibrationSession.Step), failed(String), done }

    private var page: Page {
        if !started { return .intro }
        if let error = service.saveError { return .failed(error) }
        if shown == .done { return .done }
        if service.accessDenied { return .denied }
        if !service.isReceiving { return .waiting }
        return .step(shown)
    }

    var body: some View {
        VStack(spacing: 0) {
            StepTrack(current: started ? shown : nil, stepDone: stepDone)
                .padding(.top, 24)
                .opacity(started ? 1 : 0)
            figure
                .frame(width: 240, height: 210)
                .padding(.top, 18)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 8)
            if case .step(let step) = page {
                meter(step)
                    .padding(.top, 14)
            }
            if let note {
                Label(note.text, systemImage: note.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .padding(.top, 14)
            }
            Spacer(minLength: 16)
            buttons
                .padding(20)
        }
        .frame(width: 480, height: 540)
        .animation(.easeInOut(duration: 0.25), value: page)
        .onChange(of: service.calibration?.step) { _, step in
            guard let step, step != shown else { return }
            stepDone = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                stepDone = false
                shown = step
            }
        }
        .onDisappear { service.endCalibration() }
    }

    // MARK: The head and the step's progress

    private var figure: some View {
        ZStack {
            switch page {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(.white, Color.accentColor)
                    .symbolEffect(.bounce, value: page == .done)
                    .transition(.scale.combined(with: .opacity))
            case .denied, .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.secondary)
            case .waiting:
                Image(systemName: "airpodspro")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            case .intro:
                HeadFigure(pitch: 0, yaw: 0, roll: 0)
            case .step:
                HeadFigure(pitch: service.pose.pitch, yaw: service.pose.yaw, roll: service.pose.roll)
                    .opacity(stepDone ? 0.35 : 1)
                    .overlay {
                        if stepDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 54))
                                .foregroundStyle(.white, Color.accentColor)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3), value: stepDone)
            }
        }
    }

    /// Nods and shakes are counted in dots; the held steps fill a bar.
    @ViewBuilder private func meter(_ step: CalibrationSession.Step) -> some View {
        if step == .nod || step == .shake {
            HStack(spacing: 10) {
                ForEach(0..<CalibrationSession.repetitionsNeeded, id: \.self) { i in
                    Circle()
                        .fill(i < repetitions ? Color.accentColor : Color.primary.opacity(0.14))
                        .frame(width: 12, height: 12)
                        .animation(.easeOut(duration: 0.2), value: repetitions)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(repetitions) of \(CalibrationSession.repetitionsNeeded)")
        } else {
            ProgressView(value: stepDone ? 1 : stepProgress)
                .frame(width: 220)
                .animation(.easeOut(duration: 0.2), value: stepProgress)
        }
    }

    private var stepProgress: Double {
        guard case .step(let step) = page, service.calibration?.step == step else { return 0 }
        return service.calibration?.progress ?? 0
    }

    // MARK: Words

    private var title: String {
        switch page {
        case .intro: "Set Up Head Gestures"
        case .denied: "Motion Access Is Off"
        case .waiting: "Put In Your AirPods"
        case .failed: "Couldn't Save the Calibration"
        case .done: "Head Gestures Are Set Up"
        case .step(.still): "Look at the Screen"
        case .step(.nod): "Nod"
        case .step(.shake): "Shake Your Head"
        case .step(.tiltLeft): "Tilt Left"
        case .step(.tiltRight): "Tilt Right"
        case .step(.natural): "Now Move Naturally"
        case .step(.done): ""
        }
    }

    private var detail: String {
        switch page {
        case .intro:
            "About a minute, with your AirPods in."
        case .denied:
            "Allow in System Settings → Privacy & Security → Motion & Fitness."
        case .waiting:
            "AirPods Pro, Max, or 3rd generation or later."
        case .failed(let error):
            "Nothing was stored. \(error)"
        case .done:
            "Nod: play/pause · Shake: next · Tilt: seek"
        case .step(.still): "Hold still for a moment."
        case .step(.nod): "Five times, pausing in between."
        case .step(.shake): "Five times, pausing in between."
        case .step(.tiltLeft): "Towards your left shoulder, and hold."
        case .step(.tiltRight): "Towards your right shoulder, and hold."
        case .step(.natural):
            "Look around and move as usual, without nodding or shaking."
        case .step(.done): ""
        }
    }

    private var repetitions: Int {
        service.calibration?.step == shown ? service.calibration?.repetitions ?? 0 : CalibrationSession.repetitionsNeeded
    }

    private var note: (text: String, symbol: String)? {
        switch page {
        case .intro:
            ("Stored encrypted on this Mac", "lock.fill")
        case .done:
            if let weak {
                ("Your \(weak) varied a lot. Set up again if they miss.", "exclamationmark.circle")
            } else {
                ("⌘Z undoes a gesture you didn't mean", "arrow.uturn.backward.circle.fill")
            }
        default: nil
        }
    }

    /// The gesture whose calibration takes don't recognise each other well, if any.
    private var weak: String? {
        for (label, name) in [(GestureLabel.nod, "nods"), (.shake, "shakes")] {
            if let c = service.selfCheck[label], c.recognised < c.of - 1 { return name }
        }
        return nil
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        switch page {
        case .intro:
            HStack {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Get Started") {
                    started = true
                    shown = .still
                    service.beginCalibration()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        case .done:
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .failed:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        default:
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
    }
}

/// The steps of the setup in a row: the ones done filled, the current one wider, the rest faint.
private struct StepTrack: View {
    /// Nil before setup has started.
    var current: CalibrationSession.Step?
    var stepDone: Bool
    private static let steps = CalibrationSession.Step.allCases.filter { $0 != .done }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.steps, id: \.self) { step in
                let index = current?.rawValue ?? -1
                let done = step.rawValue < index || (step.rawValue == index && stepDone)
                let isCurrent = step.rawValue == index
                Capsule()
                    .fill(done ? Color.accentColor : isCurrent ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.14))
                    .frame(width: isCurrent ? 34 : 18, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .animation(.easeInOut(duration: 0.25), value: stepDone)
        .accessibilityElement()
        .accessibilityLabel(current.map { "Step \(min($0.rawValue + 1, Self.steps.count)) of \(Self.steps.count)" } ?? "")
    }
}

/// A head and shoulders seen from the front, as in a mirror: the head tilts against the shoulders with `roll`, and the
/// band across its face (where the eyes are) slides the way it turns (`yaw`) and looks (`pitch`). Degrees from
/// looking straight ahead.
private struct HeadFigure: View {
    var pitch: Double, yaw: Double, roll: Double

    var body: some View {
        // Turning left moves the band to the left of the screen; looking down moves it down.
        let x = min(max(-yaw * 0.8, -22), 22), y = min(max(-pitch * 0.8, -20), 20)
        let fill = Color.primary.opacity(0.12), line = Color.primary.opacity(0.3)
        VStack(spacing: -8) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay { Circle().fill(fill) }
                    .overlay {
                        Capsule()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 52, height: 8)
                            .offset(x: x, y: y - 6)
                    }
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(line, lineWidth: 2) }
                    .frame(width: 104, height: 104)
                HStack(spacing: 96) {
                    pod
                    pod
                }
                .offset(y: 6)
            }
            .rotationEffect(.degrees(min(max(roll, -40), 40)), anchor: UnitPoint(x: 0.5, y: 1.05))
            UnevenRoundedRectangle(topLeadingRadius: 36, topTrailingRadius: 36)
                .fill(fill)
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: 36, topTrailingRadius: 36)
                        .strokeBorder(line, lineWidth: 2)
                }
                .frame(width: 160, height: 46)
                .zIndex(-1)
        }
        .animation(.linear(duration: 0.06), value: x)
        .animation(.linear(duration: 0.06), value: y)
        .animation(.linear(duration: 0.06), value: roll)
    }

    private var pod: some View {
        Capsule()
            .fill(.white)
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1) }
            .frame(width: 10, height: 22)
    }
}

#if DEBUG
private func still(_ seconds: Double, from t: Double = 0) -> [HeadSample] {
    (0..<Int(seconds * 50)).map { HeadSample(t: t + Double($0) / 50, pitch: -20) }
}

#Preview("Intro") {
    HeadGestureCalibrationView().environment(HeadGestureService.preview(samples: []))
}

#Preview("Still, half way") {
    PreviewStarted(service: .preview(samples: still(1.3), pose: (-4, 12, -6)))
}

#Preview("Nod") {
    PreviewStarted(service: .preview(samples: still(3), pose: (-14, 0, 0)), step: .nod)
}

/// The sheet past its first page.
private struct PreviewStarted: View {
    let service: HeadGestureService
    var step = CalibrationSession.Step.still
    var body: some View {
        HeadGestureCalibrationView(started: true, shown: step).environment(service)
    }
}
#endif

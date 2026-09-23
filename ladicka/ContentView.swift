//
//  ContentView.swift
//  ladicka
//
//  Created by Jiří Švácha on 23.09.2026.
//

import SwiftUI
import Observation
import AVFoundation
import Accelerate

// MARK: - Instruments & hard-coded standard tunings

struct InstrumentString: Identifiable {
    let id: Int
    let label: String      // shown to the user, e.g. "E"
    let name: String       // scientific pitch, e.g. "E2"
    let frequency: Double  // target frequency in Hz
}

struct Instrument: Identifiable {
    let id: Int
    let name: String
    let strings: [InstrumentString]
}

let instruments: [Instrument] = [
    Instrument(id: 0, name: "Guitar", strings: [
        InstrumentString(id: 0, label: "E", name: "E2", frequency: 82.41),
        InstrumentString(id: 1, label: "A", name: "A2", frequency: 110.00),
        InstrumentString(id: 2, label: "D", name: "D3", frequency: 146.83),
        InstrumentString(id: 3, label: "G", name: "G3", frequency: 196.00),
        InstrumentString(id: 4, label: "B", name: "B3", frequency: 246.94),
        InstrumentString(id: 5, label: "e", name: "E4", frequency: 329.63),
    ]),
    Instrument(id: 1, name: "Ukulele", strings: [
        InstrumentString(id: 0, label: "G", name: "G4", frequency: 392.00),
        InstrumentString(id: 1, label: "C", name: "C4", frequency: 261.63),
        InstrumentString(id: 2, label: "E", name: "E4", frequency: 329.63),
        InstrumentString(id: 3, label: "A", name: "A4", frequency: 440.00),
    ]),
]

/// Cents difference between a detected frequency and a target frequency.
func centsOff(from frequency: Double, to target: Double) -> Double {
    1200.0 * log2(frequency / target)
}

// MARK: - Audio engine + pitch detection

@MainActor
@Observable
final class TunerEngine {
    var isRunning = false
    var permissionDenied = false
    var frequency: Double = 0
    var nearestString: InstrumentString?
    var cents: Double = 0
    var instrument: Instrument = instruments[0]

    private let engine = AVAudioEngine()

    func toggle() {
        if isRunning { stop() } else { Task { await start() } }
    }

    /// Switches the target instrument and clears the current reading.
    func select(_ newInstrument: Instrument) {
        instrument = newInstrument
        frequency = 0
        nearestString = nil
        cents = 0
    }

    func start() async {
        guard await requestPermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let sampleRate = format.sampleRate

            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                let result = detectPitch(buffer: buffer, sampleRate: sampleRate)
                Task { @MainActor [weak self] in
                    self?.apply(result)
                }
            }

            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        frequency = 0
        nearestString = nil
        cents = 0
    }

    private func apply(_ detected: Double?) {
        guard let detected else {
            // No confident pitch (silence / noise): keep the last reading calm.
            return
        }
        // Light smoothing to steady the needle.
        frequency = frequency == 0 ? detected : frequency * 0.7 + detected * 0.3

        let closest = instrument.strings.min {
            abs(centsOff(from: frequency, to: $0.frequency)) < abs(centsOff(from: frequency, to: $1.frequency))
        }
        nearestString = closest
        if let closest {
            cents = centsOff(from: frequency, to: closest.frequency)
        }
    }

    private func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

/// Detects the fundamental frequency of a buffer using autocorrelation.
/// Runs on the audio thread, so it must not touch any actor-isolated state.
private func detectPitch(buffer: AVAudioPCMBuffer, sampleRate: Double) -> Double? {
    guard let channel = buffer.floatChannelData?[0] else { return nil }
    let n = Int(buffer.frameLength)
    guard n > 0 else { return nil }
    let samples = Array(UnsafeBufferPointer(start: channel, count: n))

    // Gate on loudness so background noise doesn't produce a reading.
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
    guard rms > 0.01 else { return nil }

    // Only search lags for frequencies a guitar can produce (~60–600 Hz).
    let maxLag = min(n - 1, Int(sampleRate / 60.0))
    let minLag = max(1, Int(sampleRate / 600.0))
    guard maxLag > minLag else { return nil }

    var correlation = [Float](repeating: 0, count: maxLag + 1)
    for lag in 0...maxLag {
        var sum: Float = 0
        vDSP_dotpr(samples, 1, Array(samples[lag...]), 1, &sum, vDSP_Length(n - lag))
        correlation[lag] = sum
    }

    // Skip the peak at lag 0 by moving past the first descent below zero.
    var lag = minLag
    while lag < maxLag && correlation[lag] > 0 { lag += 1 }

    var bestLag = -1
    var bestValue: Float = 0
    while lag <= maxLag {
        if correlation[lag] > bestValue {
            bestValue = correlation[lag]
            bestLag = lag
        }
        lag += 1
    }
    guard bestLag > 0 else { return nil }

    // Parabolic interpolation around the peak for sub-sample accuracy.
    var refined = Double(bestLag)
    if bestLag > 0 && bestLag < maxLag {
        let a = correlation[bestLag - 1]
        let b = correlation[bestLag]
        let c = correlation[bestLag + 1]
        let denom = a - 2 * b + c
        if denom != 0 {
            refined += Double((a - c) / (2 * denom))
        }
    }

    let frequency = sampleRate / refined
    guard frequency > 60, frequency < 600 else { return nil }
    return frequency
}

// MARK: - UI

struct ContentView: View {
    @State private var tuner = TunerEngine()

    private var inTune: Bool {
        tuner.nearestString != nil && abs(tuner.cents) < 5
    }

    var body: some View {
        VStack(spacing: 40) {
            Text("Ladička")
                .font(.largeTitle.bold())

            // Instrument picker
            Picker("Instrument", selection: Binding(
                get: { tuner.instrument.id },
                set: { id in
                    if let choice = instruments.first(where: { $0.id == id }) {
                        tuner.select(choice)
                    }
                }
            )) {
                ForEach(instruments) { instrument in
                    Text(instrument.name).tag(instrument.id)
                }
            }
            .pickerStyle(.segmented)

            // Detected note
            VStack(spacing: 4) {
                Text(tuner.nearestString?.label ?? "–")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(inTune ? .green : .primary)
                    .contentTransition(.numericText())
                Text(tuner.frequency > 0 ? String(format: "%.1f Hz", tuner.frequency) : " ")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Tuning meter
            TuningMeter(cents: tuner.nearestString == nil ? 0 : tuner.cents,
                        active: tuner.nearestString != nil)

            Text(statusText)
                .font(.headline)
                .foregroundStyle(inTune ? .green : .secondary)

            // Target strings
            HStack(spacing: 12) {
                ForEach(tuner.instrument.strings) { string in
                    let isCurrent = tuner.nearestString?.id == string.id
                    Text(string.label)
                        .font(.headline.monospaced())
                        .frame(width: 40, height: 40)
                        .background(isCurrent ? Color.accentColor : Color.gray.opacity(0.2))
                        .foregroundStyle(isCurrent ? .white : .primary)
                        .clipShape(Circle())
                }
            }

            Spacer()

            Button(action: tuner.toggle) {
                Text(tuner.isRunning ? "Stop" : "Start")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(tuner.isRunning ? Color.red : Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if tuner.permissionDenied {
                Text("Microphone access is off. Enable it in Settings to tune.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private var statusText: String {
        guard tuner.nearestString != nil else {
            return tuner.isRunning ? "Play a string…" : "Tap Start"
        }
        if inTune { return "In tune" }
        return tuner.cents < 0 ? "Too low — tighten" : "Too high — loosen"
    }
}

/// A simple needle that moves left (flat) or right (sharp) from center.
struct TuningMeter: View {
    let cents: Double   // -50 ... +50
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(-50, min(50, cents))
            let x = width / 2 + CGFloat(clamped / 50) * (width / 2 - 12)

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 10)
                    .frame(maxHeight: .infinity)

                // Center "in tune" marker
                Rectangle()
                    .fill(Color.green.opacity(0.6))
                    .frame(width: 2)
                    .position(x: width / 2, y: geo.size.height / 2)

                // Needle
                Circle()
                    .fill(active ? (abs(cents) < 5 ? Color.green : Color.orange) : Color.gray)
                    .frame(width: 24, height: 24)
                    .position(x: x, y: geo.size.height / 2)
                    .animation(.easeOut(duration: 0.1), value: x)
            }
        }
        .frame(height: 40)
        .padding(.horizontal)
    }
}

#Preview {
    ContentView()
}

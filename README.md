# Ladička

A dead-simple guitar & ukulele tuner for iOS, built with SwiftUI.

## Features

- Real-time pitch detection from the microphone (autocorrelation).
- Pick your instrument with one tap:
  - **Guitar** — standard tuning: E2, A2, D3, G3, B3, E4
  - **Ukulele** — standard tuning: G4, C4, E4, A4
- Shows the nearest note, the exact frequency in Hz, and a needle that tells you if you're flat or sharp.
- Minimal UI: one **Start/Stop** button and nothing to configure.

## Requirements

- iOS 17+
- Xcode 16+
- A real device (the Simulator has no microphone input)

## Build & Run

1. Open `ladicka.xcodeproj` in Xcode.
2. Select your development team under **Signing & Capabilities**.
3. Run on a physical device.

> The app needs microphone access. The usage description is set via the
> `NSMicrophoneUsageDescription` Info.plist key.

## How it works

Audio is captured with `AVAudioEngine`. Each buffer is run through an
autocorrelation-based pitch detector (with a loudness gate to ignore
background noise), and the detected frequency is matched to the nearest
string of the selected instrument. The deviation is shown in cents.

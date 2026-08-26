import AppKit
import AVFoundation
import CoreGraphics
import FluidAudio

// dictate — offline push-to-talk dictation for macOS.
// Tap § to start recording, tap again to transcribe at the cursor.
// Double-tap § types a literal §; Ctrl+§ discards.
// Indicator: ✦ blinks in the menu bar while recording.

let SAMPLE_RATE = 16000

let stateLock = NSLock()
func withStateLock<T>(_ body: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body()
}

// Shared state (all access under stateLock unless noted)
var buffer: [Float] = []
var isRecording = false
var isTranscribing = false
var modelsReady = false
var runningSession: (engine: AVAudioEngine, observer: NSObjectProtocol)?  // now paired
var keyWasUp = true   // edge detection for the hotkey
let DOUBLE_TAP_WINDOW = 0.5   // clip shorter than this = double-tap, type a literal §

// -------- Recording indicator --------
var statusItem: NSStatusItem!
var blinkTimer: DispatchSourceTimer?
var blinkOn = false

func startIndicator() {
    DispatchQueue.main.async {
        statusItem.button?.title = "✦"
        blinkOn = true
    }
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    t.schedule(deadline: .now() + 0.45, repeating: 0.9)
    t.setEventHandler {
        blinkOn.toggle()
        statusItem.button?.title = blinkOn ? "✦" : "✧"
    }
    t.resume()
    blinkTimer = t
}

func stopIndicator() {
    blinkTimer?.cancel()
    blinkTimer = nil
    DispatchQueue.main.async { statusItem.button?.title = "✧" }
}

// -------- Typing --------
func typeText(_ text: String) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let u16 = Array(text.utf16)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
    down.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: u16)
    up.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: u16)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// -------- Recording --------

// Installs the tap using the input node's CURRENT native format. Called at
// record start and again on .AVAudioEngineConfigurationChange.
func installTap(on eng: AVAudioEngine) {
    let hw = eng.inputNode.outputFormat(forBus: 0)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: Double(SAMPLE_RATE), channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: hw, to: target)!

    eng.inputNode.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / hw.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: frames))
        withStateLock {
            if isRecording { buffer.append(contentsOf: samples) }   // accept audio only while recording
        }
    }
}

func startRecording() -> TimeInterval? {
    let canStart = withStateLock { () -> Bool in
        if isRecording || isTranscribing || !modelsReady { return false }
        isRecording = true
        buffer.removeAll(keepingCapacity: true)
        return true
    }
    guard canStart else { return nil }

    let eng = AVAudioEngine()
    installTap(on: eng)

    let obs = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main
    ) { _ in
        guard withStateLock({ runningSession?.engine === eng && isRecording }) else { return }
        eng.inputNode.removeTap(onBus: 0)
        installTap(on: eng)
        if !eng.isRunning { try? eng.start() }
    }

    do {
        try eng.start()
    } catch {
        withStateLock {
            NotificationCenter.default.removeObserver(obs)
            runningSession = nil
            isRecording = false
        }
        fputs("❌ Failed to start audio engine: \(error)\n", stderr)
        return nil
    }

    let startTime = CFAbsoluteTimeGetCurrent()
    withStateLock {
        runningSession = (eng, obs)
    }
    startIndicator()
    return startTime
}

// Synchronous stop – returns the captured audio buffer.
func stopRecordingSync() -> [Float]? {
    stopIndicator()

    let session: (engine: AVAudioEngine, observer: NSObjectProtocol)? = withStateLock {
        guard isRecording else { return nil }
        isRecording = false
        let s = runningSession
        runningSession = nil
        return s
    }

    if let (eng, obs) = session {
        NotificationCenter.default.removeObserver(obs)
        eng.stop()
        eng.inputNode.removeTap(onBus: 0)
    }

    return withStateLock {
        let s = buffer
        buffer.removeAll(keepingCapacity: false)
        return s
    }
}

func transcribe(_ samples: [Float], discard: Bool) async {
    defer { withStateLock { isTranscribing = false } }
    guard !discard, samples.count > SAMPLE_RATE / 2 else { return }

    do {
        var decoderState = try TdtDecoderState()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        if !result.text.isEmpty {
            await MainActor.run { typeText(result.text + " ") }
        }
    } catch {
        fputs("❌ Transcription failed: \(error)\n", stderr)
    }
}

// -------- Setup --------
let asr = AsrManager(config: .default)

statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.button?.title = "⏳"   // loading

let HOTKEY = Int64(10)   // § (kVK_ISO_Section)

let callback: CGEventTapCallBack = { _, _, event, _ in
    let kc = event.getIntegerValueField(.keyboardEventKeycode)
    let f = event.flags
    let otherModifiers = f.contains(.maskShift) || f.contains(.maskAlternate) ||
                         f.contains(.maskCommand) || f.contains(.maskSecondaryFn)
    if kc == HOTKEY && !otherModifiers {
        let isDown = event.type == .keyDown
        if isDown && keyWasUp {
            if withStateLock({ isRecording }) {
                let discard = event.flags.contains(.maskControl)
                if let samples = stopRecordingSync() {
                    // Use the start time captured when we began recording
                    let elapsed = CFAbsoluteTimeGetCurrent() - (recordingStartTime ?? 0)
                    if !discard && elapsed < DOUBLE_TAP_WINDOW {
                        DispatchQueue.main.async { typeText("§") }
                    } else {
                        withStateLock { isTranscribing = true }
                        Task { await transcribe(samples, discard: discard) }
                    }
                }
                recordingStartTime = nil
            } else {
                // Start recording and remember the start time
                recordingStartTime = startRecording()
            }
        }
        withStateLock { keyWasUp = !isDown }
        return nil   // swallow the hotkey
    }
    return Unmanaged.passUnretained(event)
}

// Local variable to hold the start time – lives inside the callback's closure context
var recordingStartTime: TimeInterval? = nil

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: (1 << CGEventType.keyDown.rawValue) |
                                                    (1 << CGEventType.keyUp.rawValue),
                                  callback: callback, userInfo: nil) else {
    fputs("❌ Failed to create event tap. Grant Accessibility permission.\n", stderr)
    exit(1)
}
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
CGEvent.tapEnable(tap: tap, enable: true)

Task.detached {
    do {
        try await asr.loadModels(AsrModels.downloadAndLoad(version: .v3))
        withStateLock { modelsReady = true }
        await MainActor.run { statusItem.button?.title = "✧" }
        fputs("✅ Model loaded. Tap § to toggle dictation, double-tap to type §, Ctrl+§ discards.\n", stderr)
    } catch {
        fputs("❌ Failed to load ASR models: \(error)\n", stderr)
        await MainActor.run { statusItem.button?.title = "✕" }
        exit(1)
    }
}

// Watchdog: re-enable event tap if disabled (e.g. by Secure Input)
let tapWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
tapWatchdog.schedule(deadline: .now() + 10, repeating: 10)
tapWatchdog.setEventHandler {
    if !CGEvent.tapIsEnabled(tap: tap) {
        fputs("⚠️  Event tap was disabled (Secure Input?); re-enabling.\n", stderr)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
tapWatchdog.resume()

RunLoop.main.run()

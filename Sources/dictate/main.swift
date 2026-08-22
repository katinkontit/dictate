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
var engine: AVAudioEngine?
var isRecording = false
var isTranscribing = false
var acceptingAudio = false
var modelsReady = false
var recordStart = TimeInterval(0)
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
func startRecording() {
    let canStart = withStateLock { () -> Bool in
        if isRecording || isTranscribing || !modelsReady { return false }
        isRecording = true
        acceptingAudio = true
        buffer.removeAll(keepingCapacity: true)
        return true
    }
    guard canStart else { return }

    let eng = AVAudioEngine()
    let hw = eng.inputNode.outputFormat(forBus: 0)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: Double(SAMPLE_RATE), channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: hw, to: target)!

    eng.inputNode.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / hw.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }   // never feed the same buffer twice
            fed = true
            status.pointee = .haveData
            return buf
        }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: frames))
        withStateLock {
            if acceptingAudio { buffer.append(contentsOf: samples) }   // unbounded by design
        }
    }

    withStateLock { engine = eng }
    do {
        try eng.start()
    } catch {
        withStateLock {
            engine = nil
            isRecording = false
            acceptingAudio = false
        }
        fputs("❌ Failed to start audio engine: \(error)\n", stderr)
        return
    }
    recordStart = CFAbsoluteTimeGetCurrent()
    startIndicator()
}

// Synchronous stop so a quick § re-press between utterances is never dropped.
func stopRecordingSync() -> [Float]? {
    stopIndicator()

    let eng: AVAudioEngine? = withStateLock {
        guard isRecording else { return nil }
        isRecording = false
        acceptingAudio = false
        isTranscribing = true
        let e = engine
        engine = nil
        return e
    }

    eng?.stop()
    eng?.inputNode.removeTap(onBus: 0)

    return withStateLock {
        let s = buffer
        buffer.removeAll(keepingCapacity: false)   // release the audio back to the OS
        return s
    }
}

func transcribe(_ samples: [Float], discard: Bool) async {
    defer { withStateLock { isTranscribing = false } }
    guard !discard, samples.count > SAMPLE_RATE / 2 else { return }   // min half second

    do {
        var decoderState = try TdtDecoderState()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        if !result.text.isEmpty {
            await MainActor.run { typeText(result.text + " ") }
        }
    } catch {
        fputs("❌ Transcription failed: \(error)\n", stderr)
        DispatchQueue.main.async { statusItem.button?.title = "✧" }
    }
}

// -------- Setup --------
let asr = AsrManager(config: .default)

// Set up the status item and event tap on the main thread immediately; the run
// loop starts right away and model loading proceeds off-thread. Recording is
// gated on `modelsReady`, so nothing blocks and no main-thread wait can deadlock
// if FluidAudio (or URLSession) ever hops to the main queue during load.
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.button?.title = "⏳"   // loading

let HOTKEY = Int64(10)   // § (kVK_ISO_Section; the ANSI grave key is 50)
let debugKeys = ProcessInfo.processInfo.environment["DICTATE_DEBUG"] != nil

let callback: CGEventTapCallBack = { _, _, event, _ in
    let kc = event.getIntegerValueField(.keyboardEventKeycode)
    if debugKeys { fputs("[debug] type=\(event.type) kc=\(kc)\n", stderr) }
    // Claim the key only for bare § and Ctrl+§; Shift+§ (°), Option+§, etc. pass through untouched.
    let f = event.flags
    let otherModifiers = f.contains(.maskShift) || f.contains(.maskAlternate) ||
                         f.contains(.maskCommand) || f.contains(.maskSecondaryFn)
    if kc == HOTKEY && !otherModifiers {
        // § produces keyDown/keyUp events rather than flagsChanged; act on the DOWN edge only.
        let isDown = event.type == .keyDown
        if isDown && keyWasUp {
            if withStateLock({ isRecording }) {
                let discard = event.flags.contains(.maskControl)
                if let samples = stopRecordingSync() {
                    // Quick re-tap: not speech, just someone typing §. Emit the symbol.
                    if !discard && CFAbsoluteTimeGetCurrent() - recordStart < DOUBLE_TAP_WINDOW {
                        withStateLock { isTranscribing = false }   // no transcription will run to clear it
                        DispatchQueue.main.async { typeText("§") }
                    } else {
                        Task { await transcribe(samples, discard: discard) }
                    }
                }
            } else {
                startRecording()
            }
        }
        withStateLock { keyWasUp = !isDown }
        return nil   // swallow the hotkey so § never reaches the target app
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .defaultTap,   // filter, not just listen: we swallow §
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
        try await asr.loadModels(AsrModels.downloadAndLoad(version: .v3))  // ~480 MB download on first run only
        withStateLock { modelsReady = true }
        await MainActor.run { statusItem.button?.title = "✧" }
        fputs("✅ Model loaded. Tap § to toggle dictation, double-tap to type §, Ctrl+§ discards.\n", stderr)
    } catch {
        fputs("❌ Failed to load ASR models: \(error)\n", stderr)
        await MainActor.run { statusItem.button?.title = "✕" }
        exit(1)
    }
}

RunLoop.main.run()   // never returns; services the event-tap Mach port source

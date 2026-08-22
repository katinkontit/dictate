import AppKit
import AVFoundation
import CoreGraphics
import FluidAudio

// dictate — offline push-to-talk dictation for macOS.
// Tap Fn/Globe to start recording, tap again to transcribe at the cursor.
// Ctrl+Fn discards. Indicator: ✦ blinks in the menu bar while recording.

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
var fnWasDown = false

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
        if isRecording || isTranscribing { return false }
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
    try! eng.start()
    startIndicator()
}

// Synchronous stop so a quick Fn re-press between utterances is never dropped.
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
    guard !discard, samples.count > SAMPLE_RATE / 3 else { return }

    var decoderState = try! TdtDecoderState()
    let result = try! await asr.transcribe(samples, decoderState: &decoderState)
    if !result.text.isEmpty {
        await MainActor.run { typeText(result.text + " ") }
    }
}

// -------- Setup --------
asr = AsrManager(config: .default)

// Load models off-thread; main thread waits, then sets up the tap synchronously.
// (An unstructured top-level Task would let the process exit before setup runs.)
let modelsLoaded = DispatchSemaphore(value: 0)
Task.detached {
    try! await asr.loadModels(AsrModels.downloadAndLoad(version: .v3))  // ~480 MB download on first run only
    fputs("✅ Model loaded. Tap Fn/Globe to toggle dictation, Ctrl+Fn tap to discard.\n", stderr)
    modelsLoaded.signal()
}
modelsLoaded.wait()

statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.button?.title = "✧"

let callback: CGEventTapCallBack = { _, _, event, _ in
    let kc = event.getIntegerValueField(.keyboardEventKeycode)
    if kc == 63 || kc == 179 {
        let fnDown = event.flags.contains(.maskSecondaryFn)
        if fnDown && !fnWasDown {                       // act on the DOWN edge only
            if withStateLock({ isRecording }) {
                let discard = event.flags.contains(.maskControl)
                if let samples = stopRecordingSync() {
                    Task { await transcribe(samples, discard: discard) }
                }
            } else {
                startRecording()
            }
        }
        withStateLock { fnWasDown = fnDown }
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue,
                                  callback: callback, userInfo: nil) else {
    fputs("❌ Failed to create event tap. Grant Accessibility permission.\n", stderr)
    exit(1)
}
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
CGEvent.tapEnable(tap: tap, enable: true)

RunLoop.main.run()   // never returns; services the event-tap Mach port source

import SwiftUI
import AVFoundation

// MARK: - Sound types

enum SoundType: Int, CaseIterable {
    case voice, saxophone, keyboard, trombone, bubbles, bells

    var label: String {
        switch self {
        case .voice:     return "Voice"
        case .saxophone: return "Sax"
        case .keyboard:  return "Keys"
        case .trombone:  return "Bone"
        case .bubbles:   return "Bubbles"
        case .bells:     return "Afternoon"
        }
    }

    var filename: String {
        switch self {
        case .voice:     return ""
        case .saxophone: return "01 - dedicated to multi-instrumentalist jack gell"
        case .keyboard:  return "keyboard"
        case .trombone:  return "trombone"
        case .bubbles:   return ""
        case .bells:     return ""
        }
    }
}

// MARK: - Sound engine

class SoundEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()   // changes rate & pitch together
    private var synthNode: AVAudioSourceNode?

    private var sampleBuffers: [SoundType: AVAudioPCMBuffer] = [:]
    private var loadedType: SoundType? = nil

    // Written from main thread, read from audio thread — intentionally unsynchronized (Float reads are atomic enough here)
    var synthVelocity: Double = 0
    var synthSoundType: SoundType = .saxophone
    private var synthPhase: Double = 0
    private var synthAmp: Double = 0

    // Juno chord state — 4 voices with individual detuned phases and chorus
    private var junoPhases: [Double] = [0, 0, 0, 0]
    private var junoChorusPhase: Double = 0
    private var junoFilterState: Double = 0

    var velocity: Double = 0
    var soundType: SoundType = .voice
    var stopScratchAmount: Double = 0
    var stopScratchRate: Double = 1.0
    private var scratchPhase: Double = 0
    private var scratchSampleOffset: AVAudioFramePosition = 0
    private var scratchBuffer: AVAudioPCMBuffer? = nil

    private struct Bubble { var phase, freq, amp, decay: Double }
    private var bubbles: [Bubble] = []
    private var bubbleTimer: Int = 0
    private var waterNoise: Double = 0

    private struct BellVoice { var phase, freq, amp, target: Double; var timer: Int }
    private static let bellFreqs: [Double] = [65.41, 98.00, 116.54, 130.81, 155.56, 174.61, 196.00, 233.08, 261.63, 311.13, 349.23, 392.00, 466.16]
    private var bellVoices: [BellVoice] = []
    private var bellsInit = false
    private let bellReverb = AVAudioUnitReverb()

    init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        for type in SoundType.allCases where type != .voice {
            if let buf = loadBuffer(named: type.filename) {
                sampleBuffers[type] = trimStart(buf, seconds: 1.0) ?? buf
            }
        }

        let sampleRate: Double = 44100
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        synthNode = AVAudioSourceNode(format: monoFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let ptr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let vel = abs(self.synthVelocity)
            let signedVel = self.synthVelocity
            let hasSample = self.sampleBuffers[self.synthSoundType] != nil
            let isKeys   = self.synthSoundType == .keyboard
            let isBubbles = self.synthSoundType == .bubbles
            let isBells  = self.synthSoundType == .bells
            let targetAmp: Double
            if self.synthSoundType == .voice || hasSample || isBubbles || isBells {
                targetAmp = 0.0
            } else if isKeys {
                targetAmp = min(vel / 120.0, 0.5)
            } else {
                targetAmp = min(vel / 300.0, 0.45)
            }

            // Juno chord: Cm7 voicing — C3, Eb3, G3, Bb3
            // Pitch drops as spinner slows down
            let pitchScale = max(0.5, min(vel / 200.0, 1.0))
            let junoFreqs: [Double] = [130.81 * pitchScale, 155.56 * pitchScale, 196.0 * pitchScale, 233.08 * pitchScale]
            // Chorus LFO detune amounts per voice (spread)
            let detuneAmounts: [Double] = [0.998, 1.004, 0.996, 1.003]

            for frame in 0..<Int(frameCount) {
                let smoothing = isKeys ? (targetAmp > self.synthAmp ? 0.03 : 0.015) : 0.002
                self.synthAmp += (targetAmp - self.synthAmp) * smoothing

                var s: Double
                if isKeys {
                    // Chorus LFO
                    self.junoChorusPhase += 0.6 / sampleRate  // slow ~0.6 Hz chorus
                    if self.junoChorusPhase >= 1.0 { self.junoChorusPhase -= 1.0 }
                    let chorusMod = sin(2.0 * Double.pi * self.junoChorusPhase)

                    var mix = 0.0
                    for i in 0..<4 {
                        // Detune with chorus modulation
                        let detune = detuneAmounts[i] + chorusMod * 0.002
                        let f = junoFreqs[i] * detune
                        self.junoPhases[i] += f / sampleRate
                        if self.junoPhases[i] >= 1.0 { self.junoPhases[i] -= 1.0 }

                        // Saw wave (Juno-style oscillator)
                        let saw = 2.0 * self.junoPhases[i] - 1.0
                        // Pulse wave mixed in (PWM with chorus)
                        let pw = 0.5 + chorusMod * 0.15
                        let pulse = self.junoPhases[i] < pw ? 0.6 : -0.6
                        // Mix saw + pulse
                        mix += (saw * 0.5 + pulse * 0.5) * 0.25
                    }

                    // Simple one-pole low-pass filter for warmth
                    let cutoff = 0.15 + self.synthAmp * 0.3
                    self.junoFilterState += cutoff * (mix - self.junoFilterState)
                    s = self.junoFilterState * self.synthAmp
                } else if isBubbles {
                    self.bubbleTimer -= 1
                    if vel > 5 && self.bubbleTimer <= 0 {
                        let rate = min(vel / 25.0, 25.0)
                        let interval = max(Int(sampleRate / rate * (0.5 + Double.random(in: 0...0.5))), 1)
                        self.bubbleTimer = interval
                        self.bubbles.append(Bubble(phase: 0, freq: 120 + Double.random(in: 0...400), amp: 0.18 + Double.random(in: 0...0.12), decay: 0.9988 + Double.random(in: 0...0.0008)))
                    }
                    var bsum = 0.0
                    var j = self.bubbles.count - 1
                    while j >= 0 {
                        bsum += sin(2.0 * Double.pi * self.bubbles[j].phase) * self.bubbles[j].amp
                        self.bubbles[j].phase += self.bubbles[j].freq / sampleRate
                        if self.bubbles[j].phase >= 1.0 { self.bubbles[j].phase -= 1.0 }
                        self.bubbles[j].amp *= self.bubbles[j].decay
                        if self.bubbles[j].amp < 0.001 { self.bubbles.remove(at: j) }
                        j -= 1
                    }
                    let wNoise = Double.random(in: -1...1) * 0.012
                    self.waterNoise += 0.05 * (wNoise - self.waterNoise)
                    s = bsum + self.waterNoise * min(vel / 80.0, 1.0)
                } else if isBells {
                    if !self.bellsInit {
                        self.bellsInit = true
                        self.bellVoices = (0..<8).map { _ in
                            BellVoice(phase: Double.random(in: 0...1), freq: SoundEngine.bellFreqs.randomElement()!, amp: 0, target: 0, timer: Int.random(in: 0..<Int(sampleRate * 4)))
                        }
                    }
                    var bsum = 0.0
                    for i in 0..<self.bellVoices.count {
                        self.bellVoices[i].timer -= 1
                        if self.bellVoices[i].timer <= 0 {
                            if self.bellVoices[i].target > 0 {
                                self.bellVoices[i].target = 0
                                self.bellVoices[i].timer = Int(Double.random(in: 4...10) * sampleRate)
                            } else {
                                self.bellVoices[i].freq = SoundEngine.bellFreqs.randomElement()!
                                self.bellVoices[i].target = Double.random(in: 0.09...0.14)
                                self.bellVoices[i].timer = Int(Double.random(in: 3...7) * sampleRate)
                            }
                        }
                        let k = self.bellVoices[i].target > self.bellVoices[i].amp ? 0.00001 : 0.000006
                        self.bellVoices[i].amp += (self.bellVoices[i].target - self.bellVoices[i].amp) * k
                        self.bellVoices[i].phase += self.bellVoices[i].freq / sampleRate
                        if self.bellVoices[i].phase >= 1.0 { self.bellVoices[i].phase -= 1.0 }
                        bsum += (sin(2.0 * Double.pi * self.bellVoices[i].phase) * 0.88 + sin(4.0 * Double.pi * self.bellVoices[i].phase) * 0.12) * self.bellVoices[i].amp
                    }
                    s = bsum
                } else {
                    let freq: Double
                    if self.synthSoundType == .trombone {
                        // Trombone register: Bb0 (~29 Hz) sliding up to Bb1 (~58 Hz)
                        let slide = min(vel / 300.0, 1.0)
                        freq = 29.14 * pow(2.0, slide)
                    } else {
                        let freqScale = max(0.5, min(vel / 200.0, 1.0))
                        freq = (110.0 + min(vel / 400.0, 1.0) * 220.0) * freqScale
                    }
                    s = self.synthWave(phase: self.synthPhase, type: self.synthSoundType) * self.synthAmp
                    self.synthPhase += freq / sampleRate
                    if self.synthPhase >= 1.0 { self.synthPhase -= 1.0 }
                }

                // Record-stop effect — play the sample slowing to a halt
                if self.stopScratchAmount > 0.001, let buf = self.scratchBuffer,
                   let floatData = buf.floatChannelData {
                    let frameCount = Int(buf.frameLength)
                    let channels = Int(buf.format.channelCount)
                    let idx = Int(self.scratchSampleOffset)
                    if idx >= 0 && idx < frameCount - 1 {
                        let frac = Double(self.scratchSampleOffset) - Double(idx)
                        var sample: Float = 0
                        for ch in 0..<channels {
                            let s0 = floatData[ch][idx]
                            let s1 = floatData[ch][idx + 1]
                            sample += s0 + Float(frac) * (s1 - s0)
                        }
                        sample /= Float(channels)
                        s += Double(sample) * self.stopScratchAmount
                    }
                    self.scratchSampleOffset += AVAudioFramePosition(max(self.stopScratchRate * buf.format.sampleRate / sampleRate, 0))
                    self.stopScratchRate *= 0.9997
                    self.stopScratchAmount *= 0.9998
                    if self.stopScratchRate < 0.01 { self.stopScratchAmount = 0 }
                }

                for buf in ptr {
                    let b = UnsafeMutableBufferPointer<Float>(buf)
                    if frame < b.count { b[frame] = Float(s) }
                }
            }
            return noErr
        }

        bellReverb.loadFactoryPreset(.cathedral)
        bellReverb.wetDryMix = 0
        engine.attach(playerNode)
        engine.attach(varispeed)
        engine.attach(synthNode!)
        engine.attach(bellReverb)
        engine.connect(playerNode, to: varispeed, format: nil)
        engine.connect(varispeed, to: engine.mainMixerNode, format: nil)
        engine.connect(synthNode!, to: bellReverb, format: monoFormat)
        engine.connect(bellReverb, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    func update() {
        let vel = abs(velocity)
        let hasSample = sampleBuffers[soundType] != nil
        bellReverb.wetDryMix = soundType == .bells ? 70 : 0

        if hasSample {
            synthVelocity = 0

            // Load new buffer when instrument changes
            if loadedType != soundType {
                playerNode.stop()
                if let buf = sampleBuffers[soundType] {
                    playerNode.scheduleBuffer(buf, at: nil, options: .loops)
                }
                loadedType = soundType
            }

            // Rate slows with the spinner: full speed at vel>=200, slows down to 0.5x
            let rate = Float(max(0.5, min(vel / 200.0, 1.0)))
            varispeed.rate = rate
            playerNode.volume = Float(min(vel / 80.0, 1.0))

            if vel > 2 && !playerNode.isPlaying { playerNode.play() }
            else if vel <= 2 { playerNode.pause() }
        } else {
            // Synth fallback
            synthVelocity = velocity
            synthSoundType = soundType
            loadedType = nil
            playerNode.stop()
        }
    }

    func triggerRecordStop() {
        // Grab the current sample buffer and approximate playback position
        if let buf = sampleBuffers[soundType] {
            scratchBuffer = buf
            if let lastTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: lastTime) {
                scratchSampleOffset = playerTime.sampleTime % AVAudioFramePosition(buf.frameLength)
            } else {
                scratchSampleOffset = 0
            }
        }
        playerNode.pause()
        stopScratchRate = 1.0
        stopScratchAmount = 0.25
    }

    private func trimStart(_ buffer: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer? {
        let skipFrames = AVAudioFrameCount(buffer.format.sampleRate * seconds)
        guard skipFrames < buffer.frameLength else { return nil }
        let remaining = buffer.frameLength - skipFrames
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining) else { return nil }
        trimmed.frameLength = remaining
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = trimmed.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch].advanced(by: Int(skipFrames)), count: Int(remaining))
            }
        }
        return trimmed
    }

    private func loadBuffer(named name: String) -> AVAudioPCMBuffer? {
        // Try bundle resources first
        let extensions = ["wav", "mp3", "m4a", "caf", "aiff"]
        for ext in extensions {
            guard
                let url = Bundle.main.url(forResource: name, withExtension: ext),
                let file = try? AVAudioFile(forReading: url),
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try? file.read(into: buf)
            return buf
        }
        // Try asset catalog dataset
        if let dataAsset = NSDataAsset(name: name) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".mp3")
            try? dataAsset.data.write(to: tmp)
            if let file = try? AVAudioFile(forReading: tmp),
               let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length)) {
                try? file.read(into: buf)
                return buf
            }
        }
        return nil
    }

    private func synthWave(phase: Double, type: SoundType) -> Double {
        switch type {
        case .voice:     return 0
        case .saxophone: return (2*phase-1)*0.5 + sin(2*Double.pi*phase*3)*0.25 + sin(2*Double.pi*phase*5)*0.12
        case .keyboard:  return 0  // handled by Juno synth
        case .bubbles:   return 0
        case .bells:     return 0
        case .trombone:
            // Trombone: strong fundamental + prominent odd harmonics + buzz
            let p = 2.0 * Double.pi * phase
            let fundamental = sin(p) * 0.35
            let h2 = sin(p * 2) * 0.25
            let h3 = sin(p * 3) * 0.20
            let h4 = sin(p * 4) * 0.12
            let h5 = sin(p * 5) * 0.06
            let h6 = sin(p * 6) * 0.03
            // Lip buzz: slight square-ish clip on the waveform
            let raw = fundamental + h2 + h3 + h4 + h5 + h6
            return max(-0.7, min(raw, 0.7))
        }
    }
}

// MARK: - Speech

private let synthesizer = AVSpeechSynthesizer()

private func speak(velocity: Double) {
    guard !synthesizer.isSpeaking else { return }
    #if os(iOS)
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    try? AVAudioSession.sharedInstance().setActive(true)
    #endif
    let utterance: AVSpeechUtterance
    if velocity > 0 {
        let phrases = ["旋转！", "太极！", "哎呀！", "好的好的！", "不错不错！", "哇！", "厉害啊！"]
        utterance = AVSpeechUtterance(string: phrases.randomElement()!)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
    } else {
        let phrases = ["faster", "tai chi", "keep going", "beautiful", "don't stop", "spin it"]
        utterance = AVSpeechUtterance(string: phrases.randomElement()!)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.1
    }
    synthesizer.speak(utterance)
}

// MARK: - View

struct ContentView: View {
    @StateObject private var soundEngine = SoundEngine()
    @State private var selectedSound: SoundType = .saxophone
    @State private var rotation: Double = 0
    @State private var angularVelocity: Double = 0
    @State private var isDragging = false
    @State private var lastAngle: Double? = nil
    @State private var lastDragTime: Date = Date()

    let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Spacer()

                yinYang
                    .rotationEffect(.degrees(rotation))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // Brake: if spinner was moving and we just touched it, stop it
                                if !isDragging && abs(angularVelocity) > 10 {
                                    soundEngine.triggerRecordStop()
                                    angularVelocity = 0
                                }
                                isDragging = true
                                let center = CGPoint(x: 120, y: 120)
                                let angle = atan2(
                                    Double(value.location.y - center.y),
                                    Double(value.location.x - center.x)
                                ) * 180 / .pi
                                if let last = lastAngle {
                                    var delta = angle - last
                                    if delta > 180 { delta -= 360 }
                                    if delta < -180 { delta += 360 }
                                    let now = Date()
                                    let dt = now.timeIntervalSince(lastDragTime)
                                    if dt > 0 { angularVelocity = delta / dt }
                                    rotation += delta
                                    lastDragTime = now
                                    if selectedSound == .voice && abs(angularVelocity) > 30 {
                                        speak(velocity: angularVelocity)
                                    }
                                } else {
                                    lastDragTime = Date()
                                }
                                lastAngle = angle
                            }
                            .onEnded { _ in
                                isDragging = false
                                lastAngle = nil
                            }
                    )

                Spacer()

                soundPicker
                    .padding(.bottom, 48)
            }
        }
        .onReceive(timer) { _ in
            soundEngine.velocity = angularVelocity
            soundEngine.soundType = selectedSound
            soundEngine.update()

            guard !isDragging else { return }
            guard abs(angularVelocity) > 0.1 else { angularVelocity = 0; return }
            rotation += angularVelocity * 0.016
            angularVelocity *= 0.995
        }
    }

    var soundPicker: some View {
        HStack(spacing: 0) {
            ForEach(SoundType.allCases, id: \.rawValue) { sound in
                Button {
                    selectedSound = sound
                } label: {
                    Text(sound.label)
                        .font(.system(size: 11, weight: .light))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundColor(selectedSound == sound ? .white : Color(white: 0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color(white: 0.15)).frame(height: 1)
        }
    }

    var yinYang: some View {
        ZStack {
            Circle().fill(Color(white: 0.94))
            Rectangle().fill(Color(white: 0.1)).frame(width: 120, height: 240).offset(x: -60)
            Circle().fill(Color(white: 0.1)).frame(width: 120, height: 120).offset(y: -60)
            Circle().fill(Color(white: 0.94)).frame(width: 120, height: 120).offset(y: 60)
            Circle().fill(Color(white: 0.94)).frame(width: 41, height: 41).offset(y: -60)
            Circle().fill(Color(white: 0.1)).frame(width: 41, height: 41).offset(y: 60)
        }
        .frame(width: 240, height: 240)
        .clipShape(Circle())
    }
}

#Preview {
    ContentView()
}

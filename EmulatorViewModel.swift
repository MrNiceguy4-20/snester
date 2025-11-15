import Foundation
import Combine
import SwiftUI
import MetalKit // ADDED: MetalKit for MTLBuffer

enum Key { case up, down, left, right, a, b, x, y, l, r, start, select }

class EmulatorViewModel: ObservableObject {
    @Published var framebuffer: [UInt32]
    @Published var romTitle: String = "No ROM Loaded"
    @Published var fps: Double = 0.0
    @Published var cpuRegisters: String = "CPU Halted"
    @Published var ppuRegisters: String = "PPU Halted"
    @Published var isDebugUpdating: Bool = true

    var isDebugViewVisible = false
    private let debugUpdateInterval = 10
    private var debugFrameCounter: Int = 0
    private var lastFrameTimestamp: TimeInterval = 0
    private var frameCounter: Int = 0

    private var emulatorCore: EmulatorCore
    private var audioEngine: AudioEngine // ADDED: Audio Engine instance
    private var cancellables = Set<AnyCancellable>()
    
    // ADDED: Shared MTLBuffer for fast GPU transfer (from Phase 26)
    private let videoBufferSize = 256 * 224 * MemoryLayout<UInt32>.size
    lazy var sharedVideoBuffer: MTLBuffer = {
        let device = MTLCreateSystemDefaultDevice()!
        let buffer = device.makeBuffer(length: videoBufferSize, options: .storageModeShared)!
        return buffer
    }()

    init() {
        self.emulatorCore = EmulatorCore()
        self.audioEngine = AudioEngine() // ADDED: Initialize Audio Engine
        
        self.framebuffer = Array(repeating: 0xFF000000, count: 256*224)
        
        emulatorCore.ppu.framebufferPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newFrame in
                guard let self = self else { return }
                
                
                newFrame.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    let byteCount = min(bytes.count, self.videoBufferSize)
                    self.sharedVideoBuffer.contents().copyMemory(from: baseAddress, byteCount: byteCount)
                }

                
                self.updateFPS()
            }
            .store(in: &cancellables)
            
        // ADDED: APU Audio Buffer Subscription
        emulatorCore.apu.audioBufferPublisher
            .sink { [weak self] buffer in
                self?.audioEngine.play(buffer: buffer)
            }
            .store(in: &cancellables)
            
        self.audioEngine.start()
    }

    func loadROM(from url: URL) {
        let success = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        if success {
            do {
                let romData = try Data(contentsOf: url)
                if emulatorCore.loadROM(data: romData) {
                    self.romTitle = emulatorCore.rom?.romName ?? "Unknown"
                    self.resetEmulator()
                    emulatorCore.isRunning = true
                }
            } catch { print("Failed to load ROM: \(error)") }
        }
    }

    func resetEmulator() { emulatorCore.reset() }

    func runFrame() {
        guard emulatorCore.isRunning else { return }
        emulatorCore.runFrame()
        if isDebugViewVisible && isDebugUpdating {
            debugFrameCounter += 1
            if debugFrameCounter >= debugUpdateInterval {
                cpuRegisters = emulatorCore.cpu.debugStatus()
                ppuRegisters = emulatorCore.ppu.debugStatus()
                debugFrameCounter = 0
            }
        }
    }

    private func updateFPS() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTimestamp
        if elapsed > 1.0 {
            fps = Double(frameCounter)/elapsed
            frameCounter = 0
            lastFrameTimestamp = now
        }
    }

    func handleKeyEvent(nsEvent: NSEvent, down: Bool) {
        guard !nsEvent.isARepeat else { return }
        var key: Key?
        switch nsEvent.keyCode {
        case 126: key = .up; case 125: key = .down; case 123: key = .left; case 124: key = .right
        case 0: key = .a; case 1: key = .b; case 6: key = .x; case 7: key = .y
        case 12: key = .l; case 14: key = .r
        case 49: key = .start; case 51: key = .select
        default: break
        }
        if let key = key { print("Key \(down ? "down" : "up"): \(key)") }
    }
}

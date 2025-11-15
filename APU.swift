import Foundation
import Combine

class APU {
    
    var spcRAM: [UInt8] = Array(repeating: 0, count: 64 * 1024)
    var spc700: SPC700!
    var dsp: DSP!
    
    var cpuPort: [UInt8] = Array(repeating: 0, count: 4)
    var apuPort: [UInt8] = Array(repeating: 0, count: 4)
    
    var audioBufferPublisher = PassthroughSubject<[Float], Never>()
    
    private let sampleRate: Double = 44100.0
    private var sampleBuffer: [Float] = Array(repeating: 0.0, count: 735 * 2)
    private var sampleBufferIndex = 0

    init() {
        // Assume DSP and SPC700 are initialized here
        self.dsp = DSP()
        self.spc700 = SPC700()
        self.spc700.memory = self
    }
    
    func reset() {
        spcRAM = Array(repeating: 0, count: 64 * 1024)
        spc700.reset()
        dsp.reset()
        
        cpuPort = Array(repeating: 0, count: 4)
        // FIX: Hardcoded APU Ports for initial S-CPU check (16-bit 0xBB AA)
        apuPort = [0xAA, 0xBB, 0xAA, 0xBB]
        
        // Simulating the SPC BOOT ROM
        spcRAM[Int(0xFFFC)] = 0x00
        spcRAM[Int(0xFFFD)] = 0x01
        spcRAM[Int(0x0100)] = 0x00
        spcRAM[Int(0x0101)] = 0xEB
    }
    
    func step(cycles: Int) {
        let spcCycles = cycles * 2
        
        for _ in 0..<spcCycles {
            let _ = spc700.step()
        }
        
        let cyclesToGenerate = Double(cycles) / 500.0
        generateAudioSamples(count: Int(cyclesToGenerate))
    }
    
    func generateAudioSamples(count: Int) {
        let maxIndex = sampleBuffer.count
        
        for _ in 0..<count {
            if sampleBufferIndex >= maxIndex {
                audioBufferPublisher.send(sampleBuffer)
                sampleBufferIndex = 0
            }
            
            let (left, right) = dsp.generateSample()
            
            if sampleBufferIndex + 1 < maxIndex {
                sampleBuffer[sampleBufferIndex] = left
                sampleBuffer[sampleBufferIndex + 1] = right
                sampleBufferIndex += 2
            }
        }
    }
    
    func readRegister(addr: UInt16) -> UInt8 {
        switch addr {
        case 0x2140...0x2143:
            let index = Int(addr - 0x2140)
            return apuPort[index]
        case 0x2144...0x217F:
            return 0
        default:
            return 0
        }
    }
    
    func writeRegister(addr: UInt16, data: UInt8) {
        switch addr {
        case 0x4203:
            if (data & 0x01) != 0 {
                reset()
            }
            
        case 0x2140...0x2143:
            cpuPort[Int(addr - 0x2140)] = data
            
        case 0x2144...0x217F:
            let channelIndex = Int((addr - 0x2140) / 0x10)
            let offset = (addr - 0x2140) % 0x10
            
            if channelIndex < dsp.channels.count {
                switch offset {
                case 0: dsp.channels[channelIndex].volumeLeft = data
                case 1: dsp.channels[channelIndex].volumeRight = data
                case 2: dsp.channels[channelIndex].pitch = (dsp.channels[channelIndex].pitch & 0xFF00) | UInt16(data)
                case 3: dsp.channels[channelIndex].pitch = (dsp.channels[channelIndex].pitch & 0x00FF) | (UInt16(data) << 8)
                case 4: dsp.channels[channelIndex].sampleAddress = (dsp.channels[channelIndex].sampleAddress & 0xFF00) | UInt16(data)
                case 5: dsp.channels[channelIndex].sampleAddress = (dsp.channels[channelIndex].sampleAddress & 0x00FF) | (UInt16(data) << 8)
                case 8:
                    if (data & 0x01) != 0 { dsp.channels[channelIndex].keyOn = true }
                    if (data & 0x02) != 0 { dsp.channels[channelIndex].keyOff = true }
                default: break
                }
            }
            
        default:
            break
        }
    }
}

import Foundation
import Combine

class APU {
    
    var spcRAM: [UInt8] = Array(repeating: 0, count: 64 * 1024)
    var spc700: SPC700! // Assuming this is defined elsewhere
    var dsp: DSP! // Assuming this is defined elsewhere
    
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
        self.spc700.memory = self // Assuming SPC700 needs this reference
    }
    
    func reset() {
        spcRAM = Array(repeating: 0, count: 64 * 1024)
        spc700.reset()
        dsp.reset()
        
        cpuPort = Array(repeating: 0, count: 4)
        // FIX: Corrected APU Ports for initial S-CPU check (16-bit 0xBB AA)
        // The S-CPU reads $2140,$2141,$2142,$2143.
        // Ports 0 and 1 are AA and BB for handshake.
        apuPort = [0xAA, 0xBB, 0xAA, 0xBB]
        
        // Simulating the SPC BOOT ROM
        // Note: SPC700 reset typically loads the boot ROM directly into spcRAM
        spcRAM[Int(0xFFFC)] = 0x00
        spcRAM[Int(0xFFFD)] = 0x01
        spcRAM[Int(0x0100)] = 0x00
        spcRAM[Int(0x0101)] = 0xEB
    }
    
    func step(cycles: Int) {
        let spcCycles = cycles * 2
        
        for _ in 0..<spcCycles {
            let _ = spc700.step() // Assuming SPC700.step() returns cycle count
        }
        
        let cyclesToGenerate = Double(cycles) / 500.0 // Simplified sample rate calculation
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
            // APU ports are read by S-CPU and data changes state/order. Simplified read.
            return apuPort[index]
        case 0x2144...0x217F:
            // DSP register reads, simplified to 0 for now
            return 0
        default:
            return 0
        }
    }
    
    func writeRegister(addr: UInt16, data: UInt8) {
        switch addr {
        case 0x4203: // S-CPU reset line write
            if (data & 0x01) != 0 {
                reset() // Master APU reset triggered by S-CPU
            }
            
        case 0x2140...0x2143:
            // S-CPU writes to APU ports (read by SPC700)
            cpuPort[Int(addr - 0x2140)] = data
            
        case 0x2144...0x217F:
            // S-CPU writes to DSP registers
            let registerAddr = addr - 0x2144
            let channelIndex = Int(registerAddr / 0x10)
            let offset = registerAddr % 0x10
            
            if channelIndex < dsp.channels.count {
                switch offset {
                case 0: dsp.channels[channelIndex].volumeLeft = data
                case 1: dsp.channels[channelIndex].volumeRight = data
                case 2: dsp.channels[channelIndex].pitch = (dsp.channels[channelIndex].pitch & 0xFF00) | UInt16(data)
                case 3: dsp.channels[channelIndex].pitch = (dsp.channels[channelIndex].pitch & 0x00FF) | (UInt16(data) << 8)
                case 4: dsp.channels[channelIndex].sampleAddress = (dsp.channels[channelIndex].sampleAddress & 0xFF00) | UInt16(data)
                case 5: dsp.channels[channelIndex].sampleAddress = (dsp.channels[channelIndex].sampleAddress & 0x00FF) | (UInt16(data) << 8)
                case 8: // Key On/Off register ($2148, $2158, etc.)
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

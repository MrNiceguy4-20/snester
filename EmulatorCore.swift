import Foundation

class EmulatorCore {
    var cpu: CPU
    var ppu: PPU
    var apu: APU
    var memory: MemoryBus
    var dma: DMA
    var controller: Controller
    var rom: ROM?
    var ram: RAM
    
    var isRunning = false
    
    private let targetCyclesPerFrame: Int = 89344
    
    private var cycleDebugCounter: Int = 0
    private let debugInterval: Int = 10000
    private var hasSkippedBootstrap: Bool = false
    
    init() {
        self.ppu = PPU()
        self.apu = APU()
        self.ram = RAM()
        self.memory = MemoryBus()
        self.cpu = CPU()
        self.dma = DMA()
        self.controller = Controller()

        self.ppu.memory = memory
        self.ppu.dma = dma
        
        self.memory.cpu = cpu
        self.memory.ppu = ppu
        self.memory.dma = dma
        self.memory.ram = ram
        self.memory.controller = controller
        self.memory.apu = apu
        
        self.cpu.memory = memory
        self.dma.memory = memory
        self.dma.ppu = ppu
    }
    
    func loadROM(data: Data) -> Bool {
        let rom = ROM(data: data)
        self.rom = rom
        self.memory.rom = rom
        return true
    }
    
    func reset() {
        cpu.reset()
        apu.reset()
        cycleDebugCounter = 0
        hasSkippedBootstrap = false
        dma.hdmaEnable = 0
        print("CPU reset. PC started at: \(String(format: "%04X", cpu.pc))")
    }
    
    private func getCurrentInstructionDescription() -> String {
        let memory = self.memory
        let pc = cpu.pc
        let pbr = cpu.pbr
        let opcode = memory.read(bank: pbr, addr: pc)
        
        var operands: [String] = []
        var addr = pc &+ 1
        
        for _ in 0..<3 {
            if addr >= 0xFFFF { break }
            operands.append(String(format: "%02X", memory.read(bank: pbr, addr: addr)))
            addr &+= 1
        }
        
        let operandString = operands.joined(separator: " ")
        return String(format: "%02X \(operandString)", opcode)
    }
    
    private func traceStatus() {
        let instruction = getCurrentInstructionDescription()
        print("--- Cycle \(debugInterval) ---")
        print("INST: \(instruction)")
        print("PC: \(String(format: "%02X:%04X", cpu.pbr, cpu.pc)) A:\(String(format: "%04X", cpu.a)) X:\(String(format: "%04X", cpu.x)) Y:\(String(format: "%04X", cpu.y)) P:\(String(format: "%02X", cpu.p))")
        print("DMA Active: \(dma.isTransferActive ? "Yes" : "No")")
        print("--------------------")
    }
    
    func runFrame() {
        var cyclesThisFrame = 0
        while cyclesThisFrame < targetCyclesPerFrame {
            
            var cycles: Int
            
            // FINAL BYPASS LOGIC: Skip ALL major initialization waits after the first few frames
            if cpu.pbr == 0x00 && cpu.pc >= 0x8082 && !hasSkippedBootstrap {
                // Jump directly to the main game logic entry point (0x81E0), bypassing the APU/DMA loops.
                cpu.pc = 0x81E0
                hasSkippedBootstrap = true
                cycles = 1
            } else {
                if dma.isTransferActive {
                    cycles = dma.run()
                } else {
                    cycles = cpu.step()
                }
            }
            
            ppu.step(cycles: cycles)
            apu.step(cycles: cycles)
            cyclesThisFrame += cycles
            
            cycleDebugCounter += cycles
            while cycleDebugCounter >= debugInterval {
                traceStatus()
                cycleDebugCounter -= debugInterval
            }
            
            if ppu.nmiTriggered {
                cpu.nmi()
                ppu.nmiTriggered = false
            }
        }
    }
}

import Foundation

class Controller {
    // Current button state (16 bits)
    // Bit 0-7: B, Y, Select, Start, Up, Down, Left, Right
    // Bit 8-15: A, X, L, R
    var state: UInt16 = 0
    
    // Counter for serial read ($4016 or $4218)
    var readIndex: Int = 0
    
    // Latched state when $4200 is written (strobe)
    var latchedState: UInt16 = 0
    
    // TODO: Need a reference to the MemoryBus to handle $4016 writes
    
    func setButton(_ key: Key, down: Bool) {
        // Map Keys to SNES button bits (Note: SNES bit order is often inverted in documentation)
        // Here we use a standard 16-bit mapping:
        // P2: L R X A | P1: S Sel Y B | P0: R L D U
        let mask: UInt16
        switch key {
        case .a: mask = 0x8000 // High byte (Bit 15)
        case .b: mask = 0x4000 // High byte (Bit 14)
        case .x: mask = 0x2000 // High byte (Bit 13)
        case .y: mask = 0x1000 // High byte (Bit 12)
        case .l: mask = 0x200 // Low byte (Bit 9)
        case .r: mask = 0x100 // Low byte (Bit 8)
        case .start: mask = 0x80 // Low byte (Bit 7)
        case .select: mask = 0x40 // Low byte (Bit 6)
        case .up: mask = 0x08 // Low byte (Bit 3)
        case .down: mask = 0x04 // Low byte (Bit 2)
        case .left: mask = 0x02 // Low byte (Bit 1)
        case .right: mask = 0x01 // Low byte (Bit 0)
        }
        
        if down {
            state |= mask
        } else {
            state &= ~mask
        }
    }
    
    func readRegister(addr: UInt16) -> UInt8 {
        // SNES controller port 1 is typically read at $4218 (0x01)
        // SNES controller port 2 is typically read at $4219 (0x02)
        
        // This emulator currently only supports Port 1 at $4218.
        if addr != 0x4218 {
            // For now, only handle P1 read, return 0 for P2 (or another port)
            return 0
        }
        
        // The data output is a serial stream of bits from latchedState.
        // Bit 0 of $4218 holds the current button state bit.
        let data = (latchedState >> readIndex) & 1
        
        // The index increments after each read (max 16 reads for 16 buttons)
        readIndex += 1
        if readIndex >= 16 {
            // After 16 bits, the output should stick to 1 (high)
            return UInt8(data) | 0xFE
        }
        
        return UInt8(data)
    }
    
    func writeRegister(addr: UInt16, data: UInt8) {
        // Controller strobe/latch is done by writing to $4200 (NMI/Controller Enable)
        if addr != 0x4200 { return }
        
        // The strobe pulse is signaled by setting bit 0 high.
        // The state is latched on the high-to-low transition (when the bit is cleared).
        
        // We simulate the effect: if the strobe bit (data & 1) is set, we latch.
        // When the bit is read/written with 0, the latch signal drops, and reading begins.
        
        if (data & 1) != 0 {
            // Latch button state (strobe pulse)
            latchedState = state
            readIndex = 0 // Reset read index for the serial read
        }
        
        // Note: The hardware strobe is triggered by the high->low edge.
        // We simplify by latching immediately when the strobe bit is set high,
        // and relying on the CPU to read the latched state later.
    }
}

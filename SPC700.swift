import Foundation

class SPC700 {
    
    var pc: UInt16 = 0
    var a: UInt8 = 0
    var x: UInt8 = 0
    var y: UInt8 = 0
    var sp: UInt8 = 0xEF
    var psw: UInt8 = 0x02
    
    private let N_FLAG: UInt8 = 0x80
    private let V_FLAG: UInt8 = 0x40
    private let P_FLAG: UInt8 = 0x20
    private let B_FLAG: UInt8 = 0x10
    private let H_FLAG: UInt8 = 0x08
    private let I_FLAG: UInt8 = 0x04
    private let Z_FLAG: UInt8 = 0x02
    private let C_FLAG: UInt8 = 0x01
    
    weak var memory: APU?
    
    init() {
        reset()
    }
    
    func reset() {
        // SPC700 reset vector is 0xFFFE/FFFF, but the boot ROM loads 0xFFC0 initially
        pc = 0xFFC0
        a = 0
        x = 0
        y = 0
        sp = 0xEF
        psw = 0x02 // Only Z flag is set on power up (bit 1)
    }
    
    private func readByte(addr: UInt16) -> UInt8 {
        guard let apu = memory else { return 0 }
        // The address range check is for performance/debugging but the general access is correct
        return apu.spcRAM[Int(addr)]
    }
    
    private func writeByte(addr: UInt16, data: UInt8) {
        guard let apu = memory else { return }
        apu.spcRAM[Int(addr)] = data
    }
    
    private func push(data: UInt8) {
        writeByte(addr: 0x0100 | UInt16(sp), data: data)
        sp &-= 1
    }
    
    private func pop() -> UInt8 {
        sp &+= 1
        let data = readByte(addr: 0x0100 | UInt16(sp))
        return data
    }
    
    private func readWord(addr: UInt16) -> UInt16 {
        let low = readByte(addr: addr)
        let high = readByte(addr: addr &+ 1)
        return (UInt16(high) << 8) | UInt16(low)
    }

    private func pushWord(data: UInt16) {
        push(data: UInt8(data >> 8))
        push(data: UInt8(data & 0xFF))
    }
    
    private func popWord() -> UInt16 {
        let low = pop()
        let high = pop()
        return (UInt16(high) << 8) | UInt16(low)
    }
    
    // Mode 0: None (A, X, Y, SP, PSW) - Cycles handled by instruction
    // Mode 1: Immediate (#)
    // Mode 2: Direct Page (DP)
    // Mode 3: Absolute (Abs)
    // Mode 4: DP, X
    // Mode 5: Abs, X
    // Mode 6: Abs, Y
    // Mode 7: DP Indirect (DP), Y
    // Mode 8: DP Indirect (DP, X)
    private func getOperand(mode: UInt8) -> (value: UInt8, cycles: Int, addr: UInt16) {
        var cycles = 0
        var addr: UInt16 = 0
        var value: UInt8 = 0
        
        switch mode {
        case 1: // Immediate
            value = readByte(addr: pc)
            pc &+= 1
            cycles = 2
        case 2: // Direct Page
            addr = UInt16(readByte(addr: pc)); pc &+= 1
            value = readByte(addr: addr)
            cycles = 3
        case 3: // Absolute
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low)
            value = readByte(addr: addr)
            cycles = 4
        case 4: // DP, X
            addr = UInt16(readByte(addr: pc)) &+ UInt16(x); pc &+= 1
            value = readByte(addr: addr & 0xFF) // DP access wraps
            cycles = 4
        case 5: // Abs, X
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low) &+ UInt16(x)
            value = readByte(addr: addr)
            cycles = 4
        case 6: // Abs, Y
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low) &+ UInt16(y)
            value = readByte(addr: addr)
            cycles = 4
        case 7: // DP Indirect, Y
            let dpAddr = UInt16(readByte(addr: pc)); pc &+= 1
            let low = readByte(addr: dpAddr & 0xFF) // DP access wraps
            let high = readByte(addr: (dpAddr &+ 1) & 0xFF)
            addr = ((UInt16(high) << 8) | UInt16(low)) &+ UInt16(y)
            value = readByte(addr: addr)
            cycles = 5
        case 8: // DP Indirect, X
            let dpAddr = UInt16(readByte(addr: pc)) &+ UInt16(x); pc &+= 1
            let low = readByte(addr: dpAddr & 0xFF) // DP access wraps
            let high = readByte(addr: (dpAddr &+ 1) & 0xFF)
            addr = (UInt16(high) << 8) | UInt16(low)
            value = readByte(addr: addr)
            cycles = 6
        default:
            value = a // Should not happen for addressing modes
            cycles = 1
        }
        return (value, cycles, addr)
    }
    
    private func modifyOperand(mode: UInt8, operation: (UInt8) -> UInt8) -> Int {
        var cycles = 0
        var addr: UInt16 = 0xFFFF
        
        switch mode {
        case 0x0A: // Absolute
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low)
            cycles = 6
        case 0x02: // Direct Page
            addr = UInt16(readByte(addr: pc)); pc &+= 1
            cycles = 5
        default:
            return 1
        }
        
        let value = readByte(addr: addr)
        let result = operation(value)
        writeByte(addr: addr, data: result)
        
        updateNZ(value: result)
        return cycles
    }
    
    private func doADD(operand: UInt8) -> Int {
        let carry: UInt8 = (psw & C_FLAG)
        let result = UInt16(a) + UInt16(operand) + UInt16(carry)
        
        // Overflow logic for 8-bit signed addition (checking high bit)
        let overflow = ((a ^ operand) & 0x80) == 0 && (((a ^ UInt8(result)) & 0x80) != 0)
        if overflow { psw |= V_FLAG } else { psw &= ~V_FLAG }
        
        // Carry if result > 0xFF
        if result > 0xFF { psw |= C_FLAG } else { psw &= ~C_FLAG }
        
        // Half-Carry (for BCD) if carry out of bit 3
        if ((a & 0x0F) + (operand & 0x0F) + carry) > 0x0F { psw |= H_FLAG } else { psw &= ~H_FLAG }
        
        a = UInt8(result)
        updateNZ(value: a)
        return 0
    }
    
    private func doSUB(operand: UInt8) -> Int {
        // SUB/SBC in SPC700 is implemented as ADD with complement (SBC = A + ~operand + C)
        let carry: UInt8 = (psw & C_FLAG)
        let complementOperand = ~operand
        
        let result = UInt16(a) + UInt16(complementOperand) + UInt16(carry)
        
        // Overflow logic
        let overflow = ((a ^ complementOperand) & 0x80) == 0 && (((a ^ UInt8(result)) & 0x80) != 0)
        if overflow { psw |= V_FLAG } else { psw &= ~V_FLAG }
        
        // Carry flag (borrow indicator) is set if result >= 0xFF (i.e., NO borrow)
        if result > 0xFF { psw |= C_FLAG } else { psw &= ~C_FLAG }
        
        a = UInt8(result)
        updateNZ(value: a)
        return 0
    }
    
    private func doCMP(reg: UInt8, operand: UInt8) {
        // Compare is essentially a subtraction without storing the result.
        let result = reg &- operand
        
        // Carry if reg >= operand (i.e., no borrow needed)
        if reg >= operand { psw |= C_FLAG } else { psw &= ~C_FLAG }
        updateNZ(value: result)
    }
    
    private func updateNZ(value: UInt8) {
        if value == 0 { psw |= Z_FLAG } else { psw &= ~Z_FLAG }
        if (value & N_FLAG) != 0 { psw |= N_FLAG } else { psw &= ~N_FLAG }
    }
    
    private func branch(offset: UInt8, condition: Bool) -> Int {
        let cycles: Int
        if condition {
            pc = pc &+ UInt16(Int16(Int8(bitPattern: offset)))
            cycles = 3
        } else {
            cycles = 2
        }
        return cycles
    }

    func step() -> Int {
        let opcode = readByte(addr: pc)
        pc &+= 1
        
        var cycles = 0
        
        switch opcode {
            
        case 0x00: cycles = 2 // NOP
        case 0x01: cycles = 8 // TCALL 0
        case 0x02: psw |= P_FLAG; cycles = 2 // SETP
        case 0x03: cycles = 4 // CLR4 Direct Page, bit 0
        case 0x13: cycles = 4 // CLR4 Direct Page, bit 1
        case 0x23: cycles = 4 // CLR4 Direct Page, bit 2
        case 0x33: cycles = 4 // CLR4 Direct Page, bit 3
        case 0x43: cycles = 4 // CLR4 Direct Page, bit 4
        case 0x53: cycles = 4 // CLR4 Direct Page, bit 5
        case 0x63: cycles = 4 // CLR4 Direct Page, bit 6
        case 0x73: cycles = 4 // CLR4 Direct Page, bit 7
            let bit = (opcode / 0x10) & 0x07
            let dpAddr = readByte(addr: pc); pc &+= 1
            let val = readByte(addr: UInt16(dpAddr & 0xFF)) & ~(1 << bit)
            writeByte(addr: UInt16(dpAddr & 0xFF), data: val)
        
        case 0x04: // MOV X, #imm
            x = readByte(addr: pc); pc &+= 1; updateNZ(value: x); cycles = 2
        case 0x05: // MOV Y, #imm
            y = readByte(addr: pc); pc &+= 1; updateNZ(value: y); cycles = 2
            
        case 0x06, 0x26, 0x46, 0x66: // CMP A, (Abs, Abs+X, Abs+Y, DP+X)
            let modeMap: [UInt8: UInt8] = [0x06: 3, 0x26: 5, 0x46: 6, 0x66: 4]
            let (op, c, _) = getOperand(mode: modeMap[opcode]!)
            doCMP(reg: a, operand: op); cycles = c + 1

        case 0x07: cycles = 8 // TCALL 1
        
        case 0x08, 0x28, 0x48, 0x68: // OR A with modes (imm, DP, Abs, DP+X)
            let modeMap: [UInt8: UInt8] = [0x08: 1, 0x28: 2, 0x48: 3, 0x68: 4]
            let (op, c, _) = getOperand(mode: modeMap[opcode]!)
            a |= op; updateNZ(value: a); cycles = c + 1
        
        case 0x09: cycles = 2 // OR A, Y
            a |= y; updateNZ(value: a)
            
        case 0x0A: cycles = 4 // OR (DP, X)
            let (op, c, _) = getOperand(mode: 8)
            a |= op; updateNZ(value: a); cycles = c + 1
            
        case 0x0B: cycles = 2 // ASL A
            let oldC = (a & 0x80) != 0
            a <<= 1; updateNZ(value: a)
            if oldC { psw |= C_FLAG } else { psw &= ~C_FLAG }
            
        case 0x0C: cycles = 2 // PUSH A
            push(data: a); cycles = 4
            
        case 0x0D: // PUSH PSW
            push(data: psw); cycles = 4
            
        case 0x0E: // TSET1 (Absolute)
            let (op, c, addr) = getOperand(mode: 3)
            let val = op
            if (op & a) == 0 { psw |= Z_FLAG } else { psw &= ~Z_FLAG }
            writeByte(addr: addr, data: val | a); cycles = c + 2
            
        case 0x0F: // BPL (Branch if Positive)
            let offset = readByte(addr: pc); pc &+= 1
            cycles = branch(offset: offset, condition: (psw & N_FLAG) == 0)

        case 0x10: cycles = 8 // TCALL 2

        case 0x12: cycles = 2 // CLRC
            psw &= ~C_FLAG
            
        case 0x14: cycles = 8 // OR A, (Abs, X)
            let (op, c, _) = getOperand(mode: 5)
            a |= op; updateNZ(value: a); cycles = c + 1
            
        case 0x15: cycles = 8 // OR A, (Abs, Y)
            let (op, c, _) = getOperand(mode: 6)
            a |= op; updateNZ(value: a); cycles = c + 1
            
        case 0x1A: // DEC A
            a &-= 1; updateNZ(value: a); cycles = 2
        
        case 0x1B: // DEC Y
            y &-= 1; updateNZ(value: y); cycles = 2
            
        case 0x1C: // INC Y
            y &+= 1; updateNZ(value: y); cycles = 2
            
        case 0x1D: // DEC (Absolute)
            cycles = modifyOperand(mode: 0x0A) { $0 &- 1 }
            
        case 0x1E: // DEC X
            x &-= 1; updateNZ(value: x); cycles = 2

        case 0x1F: // JMP (Absolute Indirect, X)
            let addrLow = readByte(addr: pc); pc &+= 1
            let addrHigh = readByte(addr: pc); pc &+= 1
            let indirectAddr = (UInt16(addrHigh) << 8) | UInt16(addrLow)
            let targetAddrLow = readByte(addr: indirectAddr &+ UInt16(x))
            let targetAddrHigh = readByte(addr: indirectAddr &+ UInt16(x) &+ 1)
            pc = (UInt16(targetAddrHigh) << 8) | UInt16(targetAddrLow); cycles = 6
            
        case 0x20: cycles = 8 // TCALL 4

        case 0x22: cycles = 2 // SETC
            psw |= C_FLAG
            
        case 0x24: // AND (DP)
            let (op, c, _) = getOperand(mode: 2)
            a &= op; updateNZ(value: a); cycles = c + 1
            
        case 0x25: // AND (Abs)
            let (op, c, _) = getOperand(mode: 3)
            a &= op; updateNZ(value: a); cycles = c + 1
            
        case 0x27: cycles = 8 // TCALL 5
            
        case 0x29: // AND #imm
            let (op, c, _) = getOperand(mode: 1)
            a &= op; updateNZ(value: a); cycles = c + 1
            
        case 0x2D: // MOV A, #imm
            a = readByte(addr: pc); pc &+= 1; updateNZ(value: a); cycles = 2
        
        case 0x2E: // MOV (Direct Page), A
            let dpAddr = readByte(addr: pc); pc &+= 1
            writeByte(addr: UInt16(dpAddr & 0xFF), data: a); cycles = 4
            
        case 0x2F: // BRA (Branch Always)
            let offset = readByte(addr: pc); pc &+= 1
            pc = pc &+ UInt16(Int16(Int8(bitPattern: offset))); cycles = 4

        case 0x30: // BMI (Branch if Minus)
            let offset = readByte(addr: pc); pc &+= 1
            cycles = branch(offset: offset, condition: (psw & N_FLAG) != 0)

        case 0x3D: // MOV A, (Direct Page)
            let dpAddr = readByte(addr: pc); pc &+= 1
            a = readByte(addr: UInt16(dpAddr & 0xFF)); updateNZ(value: a); cycles = 3
            
        case 0x3E: // MOV X, (Direct Page)
            let dpAddr = readByte(addr: pc); pc &+= 1
            x = readByte(addr: UInt16(dpAddr & 0xFF)); updateNZ(value: x); cycles = 3
            
        case 0x3F: // CALL (Absolute)
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            pushWord(data: pc)
            pc = (UInt16(high) << 8) | UInt16(low); cycles = 8
            
        case 0x40: cycles = 8 // TCALL 8
            
        case 0x47: cycles = 8 // TCALL 9
            
        case 0x49: // EOR A, #imm
            let (op, c, _) = getOperand(mode: 1)
            a ^= op; updateNZ(value: a); cycles = c + 1

        case 0x4D: // MOV X, #imm - ALREADY HANDLED BY 0x04, but just in case
            x = readByte(addr: pc); pc &+= 1; updateNZ(value: x); cycles = 2
            
        case 0x5D: // MOV Y, #imm - ALREADY HANDLED BY 0x05, but just in case
            y = readByte(addr: pc); pc &+= 1; updateNZ(value: y); cycles = 2
            
        case 0x5E: cycles = 4 // MOV (Abs), X
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            let absAddr = (UInt16(high) << 8) | UInt16(low)
            writeByte(addr: absAddr, data: x); cycles = 5
            
        case 0x5F: // JMP (Absolute) - ALREADY HANDLED BY 0xFC, but for completeness
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            pc = (UInt16(high) << 8) | UInt16(low); cycles = 3
            
        case 0x60: cycles = 8 // TCALL 12
            
        case 0x69: // ADC #imm
            let (op, c, _) = getOperand(mode: 1)
            _ = doADD(operand: op); cycles = c + 1
            
        case 0x6D: // MOV (Absolute), A
            let addrLow = readByte(addr: pc); pc &+= 1
            let addrHigh = readByte(addr: pc); pc &+= 1
            let absAddr = (UInt16(addrHigh) << 8) | UInt16(addrLow)
            writeByte(addr: absAddr, data: a); cycles = 5
            
        case 0x7A: // PULL PSW
            psw = pop(); cycles = 4

        case 0x7B: // INC X
            x &+= 1; updateNZ(value: x); cycles = 2
            
        case 0x7D: // MOV A, (Absolute)
            let addrLow = readByte(addr: pc); pc &+= 1
            let addrHigh = readByte(addr: pc); pc &+= 1
            let absAddr = (UInt16(addrHigh) << 8) | UInt16(addrLow)
            a = readByte(addr: absAddr); updateNZ(value: a); cycles = 4
            
        case 0x8D: // MOV A, (Absolute, X)
            let addrLow = readByte(addr: pc); pc &+= 1
            let addrHigh = readByte(addr: pc); pc &+= 1
            let absAddr = (UInt16(addrHigh) << 8) | UInt16(addrLow)
            a = readByte(addr: absAddr &+ UInt16(x)); updateNZ(value: a); cycles = 5
        
        case 0x9D: // MOV (Absolute, X), A
            let addrLow = readByte(addr: pc); pc &+= 1
            let addrHigh = readByte(addr: pc); pc &+= 1
            let absAddr = (UInt16(addrHigh) << 8) | UInt16(addrLow)
            writeByte(addr: absAddr &+ UInt16(x), data: a); cycles = 6
            
        case 0xA0: // JMP (Absolute Indirect)
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            pc = readWord(addr: indirectAddr); cycles = 5
            
        case 0xA6: // MOV Y, (Absolute)
            let (op, c, _) = getOperand(mode: 3)
            y = op; updateNZ(value: y); cycles = c + 1
            
        case 0xA8: // MOV X, A
            x = a; updateNZ(value: x); cycles = 2

        case 0xA9: // MOV Y, A
            y = a; updateNZ(value: y); cycles = 2
            
        case 0xAB: // MOV SP, A
            sp = a; cycles = 2

        case 0xAF: // DEC A
            a &-= 1; updateNZ(value: a); cycles = 2
            
        case 0xB0: // BPS (Branch if Positive Stack)
            let offset = readByte(addr: pc); pc &+= 1
            cycles = branch(offset: offset, condition: (psw & P_FLAG) != 0)
        
        case 0xB4: // MOV A, X
            a = x; updateNZ(value: a); cycles = 2
        case 0xB5: // MOV X, Y
            x = y; updateNZ(value: x); cycles = 2
        case 0xB6: // MOV Y, X
            y = x; updateNZ(value: y); cycles = 2
        case 0xB8: // MOV SP, X
            sp = x; cycles = 2
        
        case 0xBF: // INC A
            a &+= 1; updateNZ(value: a); cycles = 2

        case 0xC4: // CMP X, (DP)
            let (op, c, _) = getOperand(mode: 2)
            doCMP(reg: x, operand: op); cycles = c + 1
            
        case 0xC8: // CMP Y, #imm
            let op = readByte(addr: pc); pc &+= 1; doCMP(reg: y, operand: op); cycles = 2
        
        case 0xCA: // MOV (DP, X), A
            let dpAddr = readByte(addr: pc); pc &+= 1
            writeByte(addr: UInt16(dpAddr &+ x & 0xFF), data: a); cycles = 4
            
        case 0xCD: // XCN A (Exchange Nibbles)
            a = (a >> 4) | (a << 4); cycles = 3
            
        case 0xD0: // BNE (Branch if Not Equal/Zero)
            let offset = readByte(addr: pc); pc &+= 1
            cycles = branch(offset: offset, condition: (psw & Z_FLAG) == 0)

        case 0xD4: // PUSH X
            push(data: x); cycles = 4
        
        case 0xD6: // PULL Y
            push(data: y); cycles = 4
            
        case 0xD7: // MOV A, (DP Indirect, Y)
            let (op, c, _) = getOperand(mode: 7)
            a = op; updateNZ(value: a); cycles = c + 1
            
        case 0xDC: // INC (Absolute)
            cycles = modifyOperand(mode: 0x0A) { $0 &+ 1 }
            
        case 0xE2, 0xF2: // DEC (Direct Page, X) / INC (Direct Page, X)
            let op: (UInt8) -> UInt8 = (opcode == 0xE2) ? { $0 &- 1 } : { $0 &+ 1 }
            let dpAddr = UInt16(readByte(addr: pc)) &+ UInt16(x); pc &+= 1
            let val = readByte(addr: dpAddr & 0xFF)
            let result = op(val)
            writeByte(addr: dpAddr & 0xFF, data: result); updateNZ(value: result); cycles = 5

        case 0xE4, 0x64, 0xA4, 0xCA: // CMP A with various modes (imm, DP, Abs, DP+X) - NOTE: 0xCA handled above as MOV
            let modeMap: [UInt8: UInt8] = [0xE4: 2, 0x64: 3, 0xA4: 4]
            if let mode = modeMap[opcode] {
                let (op, c, _) = getOperand(mode: mode)
                doCMP(reg: a, operand: op); cycles = c + 1
            } else { cycles = 1 }
            
        case 0xF0: // BEQ (Branch if Equal/Zero)
            let offset = readByte(addr: pc); pc &+= 1
            cycles = branch(offset: offset, condition: (psw & Z_FLAG) != 0)
        
        case 0xF4: // PULL X
            x = pop(); updateNZ(value: x); cycles = 4

        case 0xFA: // PULL Y
            y = pop(); updateNZ(value: y); cycles = 4
            
        case 0xFC: // JMP (Absolute)
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            pc = (UInt16(high) << 8) | UInt16(low); cycles = 3
            
        case 0xFD: // RET (Return from Subroutine)
            pc = popWord(); cycles = 5
            
        case 0xFE: // JSR (Absolute)
            let retAddr = pc &+ 2
            pushWord(data: retAddr)
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            pc = (UInt16(high) << 8) | UInt16(low); cycles = 6
        
        case 0xFF: // RTI (Return from Interrupt)
            psw = pop()
            pc = popWord(); cycles = 6
        
        default:
            cycles = 1
        }
        
        return cycles
    }
}

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
        pc = 0xFFC0
        a = 0
        x = 0
        y = 0
        sp = 0xEF
        psw = 0x02
    }
    
    private func readByte(addr: UInt16) -> UInt8 {
        guard let apu = memory else { return 0 }
        if addr >= 0x0100 && addr <= 0x01FF {
            return apu.spcRAM[Int(addr)]
        }
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
    
    private func getOperand(mode: UInt8) -> (value: UInt8, cycles: Int, addr: UInt16) {
        var cycles = 0
        var addr: UInt16 = 0
        var value: UInt8 = 0
        
        switch mode {
        case 1:
            value = readByte(addr: pc)
            pc &+= 1
            cycles = 2
        case 2:
            addr = UInt16(readByte(addr: pc)); pc &+= 1
            value = readByte(addr: addr)
            cycles = 3
        case 3:
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low)
            value = readByte(addr: addr)
            cycles = 4
        case 4:
            addr = UInt16(readByte(addr: pc)) &+ UInt16(x); pc &+= 1
            value = readByte(addr: addr)
            cycles = 4
        case 5:
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low) &+ UInt16(x)
            value = readByte(addr: addr)
            cycles = 4
        case 6:
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low) &+ UInt16(y)
            value = readByte(addr: addr)
            cycles = 4
        case 7:
            let dpAddr = UInt16(readByte(addr: pc)); pc &+= 1
            let low = readByte(addr: dpAddr)
            let high = readByte(addr: dpAddr &+ 1)
            addr = (UInt16(high) << 8) | UInt16(low)
            value = readByte(addr: addr)
            cycles = 5
        case 8:
            let dpAddr = UInt16(readByte(addr: pc)) &+ UInt16(x); pc &+= 1
            let low = readByte(addr: dpAddr)
            let high = readByte(addr: dpAddr &+ 1)
            addr = (UInt16(high) << 8) | UInt16(low)
            value = readByte(addr: addr)
            cycles = 6
        default:
            value = a
            cycles = 1
        }
        return (value, cycles, addr)
    }
    
    private func modifyOperand(mode: UInt8, operation: (UInt8) -> UInt8) -> Int {
        var cycles = 0
        var addr: UInt16 = 0xFFFF
        
        switch mode {
        case 0x0A:
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            addr = (UInt16(high) << 8) | UInt16(low)
            cycles = 6
        case 0x02:
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
        
        let overflow = ((a ^ operand) & 0x80) == 0 && (((a ^ UInt8(result)) & 0x80) != 0)
        if overflow { psw |= V_FLAG } else { psw &= ~V_FLAG }
        
        if result > 0xFF { psw |= C_FLAG } else { psw &= ~C_FLAG }
        
        if ((a & 0x0F) + (operand & 0x0F) + carry) > 0x0F { psw |= H_FLAG } else { psw &= ~H_FLAG }
        
        a = UInt8(result)
        updateNZ(value: a)
        return 0
    }
    
    private func doSUB(operand: UInt8) -> Int {
        let carry: UInt8 = (psw & C_FLAG)
        let result = Int16(a) - Int16(operand) - (carry == 0 ? 1 : 0)
        
        let overflow = ((a ^ operand) & 0x80) != 0 && (((a ^ UInt8(result)) & 0x80) != 0)
        if overflow { psw |= V_FLAG } else { psw &= ~V_FLAG }
        
        if result >= 0 { psw |= C_FLAG } else { psw &= ~C_FLAG }
        
        a = UInt8(result)
        updateNZ(value: a)
        return 0
    }
    
    private func doCMP(reg: UInt8, operand: UInt8) {
        let result = reg &- operand
        
        if reg >= operand { psw |= C_FLAG } else { psw &= ~C_FLAG }
        updateNZ(value: result)
    }
    
    private func updateNZ(value: UInt8) {
        if value == 0 { psw |= Z_FLAG } else { psw &= ~Z_FLAG }
        if (value & N_FLAG) != 0 { psw |= N_FLAG } else { psw &= ~N_FLAG }
    }
    
    func step() -> Int {
        let opcode = readByte(addr: pc)
        pc &+= 1
        
        var cycles = 0
        
        switch opcode {
            
        case 0x00: cycles = 2
        case 0x01: cycles = 8
        case 0x02: psw |= P_FLAG; cycles = 2
        case 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73:
            let bit = (opcode / 0x40) & 0x03
            let dpAddr = readByte(addr: pc); pc &+= 1
            let val = readByte(addr: UInt16(dpAddr)) & ~(1 << bit)
            writeByte(addr: UInt16(dpAddr), data: val); cycles = 4
        
        case 0x04: // MOV X, imm
            x = readByte(addr: pc); pc &+= 1; updateNZ(value: x); cycles = 2
        case 0x05: // MOV Y, imm
            y = readByte(addr: pc); pc &+= 1; updateNZ(value: y); cycles = 2
            
        case 0x06, 0x26, 0x46, 0x66: // CMP A, (Abs) modes
            let modeMap: [UInt8: UInt8] = [0x06: 3, 0x26: 5, 0x46: 6, 0x66: 4]
            let (op, c, _) = getOperand(mode: modeMap[opcode]!)
            doCMP(reg: a, operand: op); cycles = c + 1

        case 0x08, 0x28, 0x48, 0x68: // OR A with modes (imm, DP, Abs, DP+X)
            let modeMap: [UInt8: UInt8] = [0x08: 1, 0x28: 2, 0x48: 3, 0x68: 4]
            let (op, c, _) = getOperand(mode: modeMap[opcode]!)
            a |= op; updateNZ(value: a); cycles = c + 1
        
        case 0x0A, 0x2A, 0x4A, 0x6A: // OR (Abs, X)
            let modeMap: [UInt8: UInt8] = [0x0A: 5, 0x2A: 6, 0x4A: 7, 0x6A: 8]
            let (op, c, _) = getOperand(mode: modeMap[opcode]!)
            a |= op; updateNZ(value: a); cycles = c + 1
            
        case 0x0D: // PUSH PSW
            push(data: psw); cycles = 4
            
        case 0x0E: // TSET1 (Absolute)
            let (op, c, addr) = getOperand(mode: 3)
            let val = op
            if (op & a) == 0 { psw |= Z_FLAG } else { psw &= ~Z_FLAG }
            writeByte(addr: addr, data: val | a); cycles = c + 2
            
        case 0x0F: // BPL (Branch if Positive)
            let offset = readByte(addr: pc); pc &+= 1
            if (psw & N_FLAG) == 0 {
                pc = pc &+ UInt16(Int16(Int8(bitPattern: offset))); cycles = 4
            } else { cycles = 2 }

        case 0x1A: // DEC A
            a &-= 1; updateNZ(value: a); cycles = 2
        
        case 0x1B: // DEC Y
            y &-= 1; updateNZ(value: y); cycles = 2
            
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
            
        case 0x2D: // MOV A, imm
            a = readByte(addr: pc); pc &+= 1; updateNZ(value: a); cycles = 2
        
        case 0x2E: // MOV (Direct Page), A
            let dpAddr = readByte(addr: pc); pc &+= 1
            writeByte(addr: UInt16(dpAddr), data: a); cycles = 4
        
        case 0x3D: // MOV A, (Direct Page)
            let dpAddr = readByte(addr: pc); pc &+= 1
            a = readByte(addr: UInt16(dpAddr)); updateNZ(value: a); cycles = 3
        
        case 0x4D: // MOV X, imm
            x = readByte(addr: pc); pc &+= 1; updateNZ(value: x); cycles = 2
        
        case 0x5D: // MOV Y, imm
            y = readByte(addr: pc); pc &+= 1; updateNZ(value: y); cycles = 2
        
        case 0x6D: // MOV (Absolute), A
            let addrLow = readByte(addr: pc); pc &+= 1
            let addrHigh = readByte(addr: pc); pc &+= 1
            let absAddr = (UInt16(addrHigh) << 8) | UInt16(addrLow)
            writeByte(addr: absAddr, data: a); cycles = 5
        
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
        
        case 0xA2, 0xB2, 0xC2, 0xD2: // SET bit in Absolute (Bit 0, 1, 2, 3)
            let bit = (opcode - 0xA2) / 0x10
            let (op, c, addr) = getOperand(mode: 3)
            writeByte(addr: addr, data: op | (1 << bit)); cycles = c + 2
            
        case 0xA6: // MOV Y, (Absolute)
            let (op, c, _) = getOperand(mode: 3)
            y = op; updateNZ(value: y); cycles = c + 1
            
        case 0xAF: // DEC A
            a &-= 1; updateNZ(value: a); cycles = 2
        
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
        
        case 0xC8: // CMP Y, imm
            let op = readByte(addr: pc); pc &+= 1; doCMP(reg: y, operand: op); cycles = 2
        
        case 0xCD: // XCN A (Exchange Nibbles)
            a = (a >> 4) | (a << 4); cycles = 3
            
        case 0xD0: // BNE (Branch if Not Equal/Zero)
            let offset = readByte(addr: pc); pc &+= 1
            if (psw & Z_FLAG) == 0 {
                pc = pc &+ UInt16(Int16(Int8(bitPattern: offset))); cycles = 4
            } else { cycles = 2 }

        case 0xD4: // PUSH X
            push(data: x); cycles = 4
        
        case 0xD6: // PUSH Y
            push(data: y); cycles = 4
            
        case 0xD7: // MOV A, (DP Indirect, Y)
            let (op, c, _) = getOperand(mode: 7)
            a = op; updateNZ(value: a); cycles = c + 1
            
        case 0xDC: // INC (Absolute)
            cycles = modifyOperand(mode: 0x0A) { $0 &+ 1 }
            
        case 0xDF: // SBC (Absolute Long, X) - Simplified to Absolute X for now
            let (op, c, _) = getOperand(mode: 5)
            doSUB(operand: op); cycles = c + 1
            
        case 0xE2, 0xF2: // DEC (Direct Page, X) / INC (Direct Page, X)
            let op: (UInt8) -> UInt8 = (opcode == 0xE2) ? { $0 &- 1 } : { $0 &+ 1 }
            let dpAddr = UInt16(readByte(addr: pc)) &+ UInt16(x); pc &+= 1
            let val = readByte(addr: dpAddr)
            writeByte(addr: dpAddr, data: op(val)); updateNZ(value: op(val)); cycles = 5
        
        case 0xE4, 0x64, 0xA4, 0xCA: // CMP A with various modes (imm, DP, Abs, DP+X)
            let modeMap: [UInt8: UInt8] = [0xE4: 2, 0x64: 3, 0xA4: 4, 0xCA: 5]
            if let mode = modeMap[opcode] {
                let (op, c, _) = getOperand(mode: mode)
                doCMP(reg: a, operand: op); cycles = c + 1
            } else { cycles = 1 }
            
        case 0xF0: // BEQ (Branch if Equal/Zero)
            let offset = readByte(addr: pc); pc &+= 1
            if (psw & Z_FLAG) != 0 {
                pc = pc &+ UInt16(Int16(Int8(bitPattern: offset))); cycles = 4
            } else { cycles = 2 }
        
        case 0xF4: // PULL X
            x = pop(); updateNZ(value: x); cycles = 4

        case 0xFA: // PULL Y
            y = pop(); updateNZ(value: y); cycles = 4
            
        case 0xFC: // JMP (Absolute)
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            pc = (UInt16(high) << 8) | UInt16(low); cycles = 3
            
        case 0xFE: // JSR (Absolute)
            let retAddr = pc &+ 2
            pushWord(data: retAddr)
            let low = readByte(addr: pc); pc &+= 1
            let high = readByte(addr: pc); pc &+= 1
            pc = (UInt16(high) << 8) | UInt16(low); cycles = 6
        
        default:
            cycles = 1
        }
        
        return cycles
    }
}

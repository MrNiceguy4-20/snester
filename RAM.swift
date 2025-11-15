//
//  RAM.swift
//  SNESEmulator
//
//  Created by (Your Name)
//

import Foundation

/// Unified RAM class for WRAM (128 KB)
/// Includes safe bounds-checking.
class RAM {
    var data: [UInt8]
        
    init() {
        self.data = Array(repeating: 0, count: 128 * 1024)
    }
    
    /// Safe read/write
    subscript(index: Int) -> UInt8 {
        get {
            guard index >= 0 && index < data.count else {
                assertionFailure("RAM read out of bounds: \(index)")
                return 0
            }
            return data[index]
        }
        set {
            guard index >= 0 && index < data.count else {
                assertionFailure("RAM write out of bounds: \(index)")
                return
            }
            data[index] = newValue
        }
    }
    
    /// Optional reset
    func clear() {
        data = Array(repeating: 0, count: data.count)
    }
}

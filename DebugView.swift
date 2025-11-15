import SwiftUI

struct DebugView: View {
    @ObservedObject var viewModel: EmulatorViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Debug Info")
                    .font(.largeTitle)
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            .padding()
            
            // --- NEW START/STOP BUTTONS ---
            HStack {
                Button("Stop Updates") {
                    viewModel.isDebugUpdating = false
                }
                .disabled(!viewModel.isDebugUpdating)
                
                Button("Start Updates") {
                    viewModel.isDebugUpdating = true
                }
                .disabled(viewModel.isDebugUpdating)
                
                Spacer()
                
                Text("FPS: \(String(format: "%.2f", viewModel.fps))")
                    .font(.system(.body, design: .monospaced))
            }
            .padding(.horizontal)
            // --- END NEW BUTTONS ---
            
            Text("CPU Registers:")
                .font(.headline)
                .padding([.top, .horizontal])
            
            // --- FIX: Added textSelection(.enabled) ---
            Text(viewModel.cpuRegisters)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)
                .frame(minHeight: 200, alignment: .top)
                .textSelection(.enabled) // <-- This makes it copyable
            
            Text("PPU Status:")
                .font(.headline)
                .padding([.top, .horizontal])
            
            // --- FIX: Added textSelection(.enabled) ---
            Text(viewModel.ppuRegisters)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)
                .frame(minHeight: 250, alignment: .top) // <-- Increased height for new info
                .textSelection(.enabled) // <-- This makes it copyable
            
            Spacer()
        }
        .frame(minWidth: 400, minHeight: 600) // Increased height
        .onAppear {
            viewModel.isDebugViewVisible = true
            viewModel.isDebugUpdating = true // Ensure it's updating when view appears
        }
        .onDisappear {
            viewModel.isDebugViewVisible = false
            viewModel.isDebugUpdating = true // Reset for next time
        }
    }
}

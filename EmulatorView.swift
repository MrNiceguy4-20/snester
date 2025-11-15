import SwiftUI
import UniformTypeIdentifiers

struct EmulatorView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @State private var isFileImporterPresented = false
    @State private var isDebugViewPresented = false // <-- New state for debug window

    var body: some View {
        VStack(spacing: 0) {
            MetalScreenView(viewModel: viewModel)
                .aspectRatio(CGSize(width: 256, height: 224), contentMode: .fit)
                .border(Color.black, width: 1)
                .onKeyDown { event in // <-- Basic controller input
                    viewModel.handleKeyEvent(nsEvent: event, down: true)
                }
                .onKeyUp { event in
                    viewModel.handleKeyEvent(nsEvent: event, down: false)
                }

            HStack {
                Button("Load ROM") {
                    isFileImporterPresented = true
                }
                
                Button("Reset") {
                    viewModel.resetEmulator()
                }
                
                // --- New Debug Button ---
                Button("Debug") {
                    isDebugViewPresented = true
                }
                
                Spacer()
                
                // --- New FPS Display ---
                Text(String(format: "FPS: %.2f", viewModel.fps))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.gray)
                
            }
            .padding()
            .background(Color(white: 0.1, opacity: 1.0))
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.loadROM(from: url)
            case .failure(let error):
                print("Error loading ROM: \(error.localizedDescription)")
            }
        }
        // --- New Sheet Modifier ---
        .sheet(isPresented: $isDebugViewPresented) {
            DebugView(viewModel: viewModel)
        }
        .edgesIgnoringSafeArea(.top)
        .background(Color.black)
        .onReceive(viewModel.$romTitle) { title in
            print("ROM Title updated: \(title)")
        }
    }
}

// --- New Key Handling ---
// This simple view modifier allows our Metal view to receive key presses
struct KeyDownHandlingModifier: ViewModifier {
    var onKeyDown: (NSEvent) -> Void
    var onKeyUp: (NSEvent) -> Void
    
    func body(content: Content) -> some View {
        content
            .background(KeyHandlingView(onKeyDown: onKeyDown, onKeyUp: onKeyUp))
    }
}

struct KeyHandlingView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void
    var onKeyUp: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyHandlingNSView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class KeyHandlingNSView: NSView {
    var onKeyDown: (NSEvent) -> Void = { _ in }
    var onKeyUp: (NSEvent) -> Void = { _ in }
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        onKeyDown(event)
    }
    
    override func keyUp(with event: NSEvent) {
        onKeyUp(event)
    }
}

extension View {
    func onKeyDown(perform action: @escaping (NSEvent) -> Void) -> some View {
        self.modifier(KeyDownHandlingModifier(onKeyDown: action, onKeyUp: { _ in }))
    }
    
    func onKeyUp(perform action: @escaping (NSEvent) -> Void) -> some View {
        self.modifier(KeyDownHandlingModifier(onKeyDown: { _ in }, onKeyUp: action))
    }
}

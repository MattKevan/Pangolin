import SwiftUI

struct CircularProgressButton: View {
    let progress: Double
    let activeTaskCount: Int
    let processingManager: ProcessingQueueManager
    let onViewAllTapped: () -> Void
    
    @State private var isAnimating = false
    @State private var showingPopover = false
    
    private var progressColor: Color {
        if activeTaskCount == 0 {
            return .green
        } else {
            return .blue
        }
    }
    
    private var iconName: String {
        if activeTaskCount == 0 {
            return "checkmark"
        } else {
            return "gearshape.2"
        }
    }
    
    var body: some View {
        Button(action: { showingPopover = true }) {
            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 24, height: 24)
                
                // Progress circle
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        progressColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(-90)) // Start from top
                    .animation(.easeInOut(duration: 0.3), value: progress)
                
                // Center icon
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(progressColor)
                    .rotationEffect(.degrees(isAnimating && activeTaskCount > 0 ? 360 : 0))
                    .animation(
                        isAnimating && activeTaskCount > 0 
                        ? .linear(duration: 2.0).repeatForever(autoreverses: false)
                        : .default,
                        value: isAnimating
                    )
                
                // Task count badge
                if activeTaskCount > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(activeTaskCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 8, y: 8)
                        }
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(helpText)
        .onAppear {
            isAnimating = activeTaskCount > 0
        }
        .onChange(of: activeTaskCount) { oldValue, newValue in
            isAnimating = newValue > 0
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ProcessingPopoverView(processingManager: processingManager) {
                showingPopover = false
                onViewAllTapped()
            }
        }
    }
    
    private var helpText: String {
        if activeTaskCount == 0 {
            return "No active processing tasks"
        } else if activeTaskCount == 1 {
            return "1 task processing - Click to view progress"
        } else {
            return "\(activeTaskCount) tasks processing - Click to view progress"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            CircularProgressButton(
                progress: 0.0,
                activeTaskCount: 0,
                processingManager: ProcessingQueueManager.shared,
                onViewAllTapped: {}
            )
            .background(Color.gray.opacity(0.1))
            
            CircularProgressButton(
                progress: 0.3,
                activeTaskCount: 2,
                processingManager: ProcessingQueueManager.shared,
                onViewAllTapped: {}
            )
            .background(Color.gray.opacity(0.1))
            
            CircularProgressButton(
                progress: 0.75,
                activeTaskCount: 5,
                processingManager: ProcessingQueueManager.shared,
                onViewAllTapped: {}
            )
            .background(Color.gray.opacity(0.1))
            
            CircularProgressButton(
                progress: 1.0,
                activeTaskCount: 0,
                processingManager: ProcessingQueueManager.shared,
                onViewAllTapped: {}
            )
            .background(Color.gray.opacity(0.1))
        }
        
        Text("Different states of the circular progress button")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding()
}
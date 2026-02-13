import SwiftUI

struct DraggableSplitter: View {
    @Binding var splitRatio: Double
    let minRatio: Double
    let maxRatio: Double
    let isVertical: Bool
    let totalSize: CGFloat
    
    @State private var isDragging = false
    @State private var initialRatio: Double = 0
    
    init(
        splitRatio: Binding<Double>,
        totalSize: CGFloat,
        minRatio: Double = 0.2,
        maxRatio: Double = 0.8,
        isVertical: Bool = true
    ) {
        self._splitRatio = splitRatio
        self.totalSize = totalSize
        self.minRatio = minRatio
        self.maxRatio = maxRatio
        self.isVertical = isVertical
    }
    
    var body: some View {
        ZStack {
            // Background area (larger hit target)
            Rectangle()
                .fill(Color.clear)
                .frame(
                    width: isVertical ? nil : 8,
                    height: isVertical ? 8 : nil
                )
            
            // Visual separator line
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(
                    width: isVertical ? nil : 1,
                    height: isVertical ? 1 : nil
                )
            
            // Drag handle (visible when hovering or dragging)
            
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            #if os(macOS)
            if hovering && !isDragging {
                if isVertical {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.resizeLeftRight.push()
                }
            } else if !hovering && !isDragging {
                NSCursor.pop()
            }
            #endif
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        initialRatio = splitRatio
                    }
                    
                    let translation = isVertical ? value.translation.height : value.translation.width
                    let ratioChange = Double(translation / totalSize)
                    let newRatio = initialRatio + ratioChange
                    
                    // Clamp the ratio to min/max bounds
                    splitRatio = max(minRatio, min(maxRatio, newRatio))
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .animation(.easeOut(duration: 0.1), value: isDragging)
    }
}


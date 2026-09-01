import SwiftUI

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // 1. Photo Save Format Selector (JPEG / DNG)
            VStack(alignment: .leading, spacing: 1) {
                Text("JPEG")
                    .font(.system(size: 9, weight: viewModel.selectedPhotoFormat == .jpeg ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedPhotoFormat == .jpeg ? .white : .white.opacity(0.35))
                
                Text("DNG")
                    .font(.system(size: 9, weight: viewModel.selectedPhotoFormat == .dng ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedPhotoFormat == .dng ? .yellow : .white.opacity(0.35))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.togglePhotoFormat()
            }
            .padding(.trailing, 2)
            
            // 2. Realtime 32-Bar RGB Spectrum Histogram (Biểu đồ Histogram màu quang phổ Realtime)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(viewModel.histogramBars) { bar in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bar.color)
                        .frame(width: 3.2, height: max(2.5, bar.height * 24.0))
                }
            }
            .frame(height: 26, alignment: .bottom)
            .padding(.horizontal, 2)
            
            // 3. Thin Vertical Separator
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 22)
            
            // 4. Realtime Exposure Info (Tốc độ màn trập & ISO)
            VStack(alignment: .trailing, spacing: 1) {
                Text(viewModel.liveShutterSpeed)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                
                Text(viewModel.liveISO)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.90))
            }
            
            // 5. Menu / Settings Dot ⋮
            Button(action: {
                viewModel.isShowingSettings = true
            }) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: 14, height: 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
        )
    }
}

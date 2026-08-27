import SwiftUI

public struct CapturedPhotoPreviewView: View {
    let item: CapturedPhotoItem
    @Environment(\.presentationMode) var presentationMode
    
    @State private var splitOffset: CGFloat = 0.5
    @State private var isShowingOriginalOnly: Bool = false
    @State private var hasSavedToPhotos: Bool = true
    
    public var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 16) {
                    // 1. Photo Viewport with Interactive Comparison
                    GeometryReader { proxy in
                        let size = proxy.size
                        ZStack {
                            // Original Image (Base)
                            Image(decorative: item.originalImage, scale: 1.0, orientation: .up)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: size.width, height: size.height)
                            
                            // Processed AI Film Image (Overlaid with Clipping Mask)
                            Image(decorative: item.processedImage, scale: 1.0, orientation: .up)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: size.width, height: size.height)
                                .mask(
                                    Rectangle()
                                        .size(
                                            width: isShowingOriginalOnly ? 0 : size.width * splitOffset,
                                            height: size.height
                                        )
                                )
                            
                            // Split Divider Line
                            if !isShowingOriginalOnly {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 2, height: size.height)
                                    .position(x: size.width * splitOffset, y: size.height / 2)
                                    .shadow(color: .black.opacity(0.5), radius: 3)
                                
                                // Drag Handle
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Image(systemName: "arrow.left.and.right")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.black)
                                    )
                                    .position(x: size.width * splitOffset, y: size.height / 2)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let newSplit = value.location.x / size.width
                                                splitOffset = max(0.05, min(0.95, newSplit))
                                            }
                                    )
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    
                    // 2. AI & Exif Metadata Dashboard
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.appliedPreset.rawValue)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    
                                    Text("•")
                                        .foregroundColor(.gray)
                                    
                                    Text(item.sceneType.rawValue)
                                        .font(.subheadline)
                                        .foregroundColor(.yellow)
                                }
                                
                                Text("Bố cục: \(item.compositionRule.rawValue) (Điểm khóa: \(Int(item.alignmentScore * 100))%)")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            
                            Spacer()
                            
                            // EXIF Capsule
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("ISO \(Int(item.iso))")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                                
                                Text(String(format: "1/%.0fs", 1.0 / max(0.0001, item.shutterSpeed)))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .padding(.horizontal, 20)
                        
                        // Compare Instruction
                        Text("Kéo thanh trượt ngang để so sánh ảnh gốc và công thức màu AI")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    
                    // 3. Action Buttons
                    HStack(spacing: 16) {
                        Button(action: {
                            isShowingOriginalOnly.toggle()
                        }) {
                            Label(isShowingOriginalOnly ? "Xem màu AI" : "Xem ảnh gốc", systemImage: "eye.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(12)
                        }
                        
                        ShareLink(
                            item: Image(decorative: item.processedImage, scale: 1.0, orientation: .up),
                            preview: SharePreview("AI Smart Framing Photo", image: Image(decorative: item.processedImage, scale: 1.0, orientation: .up))
                        ) {
                            Label("Chia sẻ", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.yellow)
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitle("Chi tiết ảnh AI", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Đóng") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.yellow)
            )
        }
    }
}

import ConductorCore
import SwiftUI

/// 设置里的「模版列表」：发现到的 Codex/openpets 宠物，各一张可选卡片（展示 idle 形象）。
/// 点选即写 `companion.templateID`（→ 落盘 + 桌宠实时换装）。
struct CompanionTemplatePicker: View {
    @Binding var selectedID: String
    /// 缓存一次发现结果，避免每次 body 求值都扫文件系统。
    @State private var pets: [CompanionPet] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(pets) { pet in
                    cell(pet)
                }
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            let discovered = CompanionPetCatalog.all()
            pets = discovered
            CodexPetCatalog.prewarm(discovered)
        }
    }

    private func cell(_ pet: CompanionPet) -> some View {
        let isSelected = pet.id == selectedID
        return VStack(spacing: 4) {
            preview(pet)
                .frame(width: 84, height: 84)
                .scaleEffect(0.52)
                .frame(width: 48, height: 48)
            Text(pet.name)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppStyle.textPrimary : AppStyle.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 64, height: 78)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AppStyle.accent.opacity(0.14) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? AppStyle.accent.opacity(0.6)
                                                  : AppStyle.textPrimary.opacity(0.08),
                                      lineWidth: isSelected ? 1.5 : 1)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selectedID = pet.id }
        }
    }

    // 模版列表用**静态**预览（animated: false）：一排宠物同时跑动画会让设置面板特别卡。
    @ViewBuilder
    private func preview(_ pet: CompanionPet) -> some View {
        switch pet.kind {
        case let .procedural(template):
            PetSprite(mood: .idle, template: template, animated: false)
        case let .atlas(url):
            if let sheet = CodexPetCatalog.sheet(at: url) {
                AtlasPetSprite(sheet: sheet, mood: .idle, animated: false)
            } else {
                PetSprite(mood: .idle, template: PetTemplateCatalog.default, animated: false)
            }
        }
    }
}

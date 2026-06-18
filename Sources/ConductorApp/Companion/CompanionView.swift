import ConductorCore
import SwiftUI

/// 透明浮窗里的伙伴：**一只**宠物 + 头顶一排「会话光点」(一会话一点、颜色=状态)。
/// 多会话不分身——光点告诉你几个在线/各啥状态；宠物只**替最该理的那个开口**：
/// 话直接飘在桌面上(无盒子、靠描边+辉光在任何壁纸上都读得清)，要你批准就身边浮发光 ✓/✗。
/// 点头顶某颗光点 → 宠物切过去替那个会话说话。
///
/// 几何（见 `CompanionController` + `CompanionPanelContentView.hitTest`）：
/// 队长固定占 pet 边的 `petZoneHeight`(原生拖拽/点击)，光点+飘字落在另一侧的 SwiftUI 区(可点)；
/// 窗口高度随内容长，队长锚点不动（顶角锚顶、底角锚底）。
struct CompanionView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject private var configStore = ConfigStore.shared
    @State private var pokeBounce = false

    var body: some View {
        ZStack(alignment: controller.petAtTop ? .top : .bottom) {
            leadPet
                .frame(width: CompanionController.windowWidth,
                       height: CompanionController.petZoneHeight)
                .frame(maxHeight: .infinity, alignment: controller.petAtTop ? .top : .bottom)

            auraStack
                .padding(controller.petAtTop ? .top : .bottom, CompanionController.petZoneHeight)
                .frame(maxHeight: .infinity, alignment: controller.petAtTop ? .top : .bottom)
        }
        .frame(width: CompanionController.windowWidth)
        .frame(maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: controller.members)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: controller.activeMemberID)
        .animation(.easeOut(duration: 0.2), value: controller.bubble)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: controller.mood)
        .id(configStore.config.appearance.theme)
        .onChange(of: controller.pokeNonce) { _, _ in
            withAnimation(.spring(response: 0.15, dampingFraction: 0.45)) { pokeBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { pokeBounce = false }
            }
        }
    }

    // MARK: 队长本体（唯一一只；周身辉光取全队聚合心情的颜色）

    private var leadPet: some View {
        Group {
            if let sheet = controller.atlasSheet {
                AtlasPetSprite(sheet: sheet, mood: controller.mood)
            } else {
                PetSprite(mood: controller.mood, template: controller.proceduralTemplate)
            }
        }
        .frame(width: 84, height: 84)
        .scaleEffect(pokeBounce ? 1.18 : 1.0)
        .shadow(color: stateColor(controller.mood).opacity(glowStrength(controller.mood)), radius: 18)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 5)
    }

    // MARK: 头顶光晕（会话光点 + 当前会话的飘字 / 摸一下卖萌）

    private var auraStack: some View {
        VStack(spacing: CompanionController.rowSpacing) {
            ForEach(auraItems) { item in
                row(for: item)
                    .transition(.scale(scale: 0.85, anchor: controller.petAtTop ? .top : .bottom)
                        .combined(with: .opacity))
            }
        }
        .frame(width: CompanionController.windowWidth)
    }

    /// 远离队长 → 贴近队长：飘字 在外、光点 贴着头顶。空闲时只有摸一下的卖萌。
    private var auraItems: [AuraItem] {
        var items: [AuraItem] = []
        if !controller.members.isEmpty {
            if let active = controller.activeMember { items.append(.speech(active)) }
            items.append(.dots)
        } else if let quip = controller.bubble {
            items.append(.quip(quip))
        }
        return controller.petAtTop ? items.reversed() : items
    }

    @ViewBuilder private func row(for item: AuraItem) -> some View {
        switch item {
        case .dots: dotsRow
        case let .speech(member): speech(for: member)
        case let .quip(text):
            Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .floatGlow(stateColor(controller.mood))
        }
    }

    private var dotsRow: some View {
        HStack(spacing: 9) {
            ForEach(controller.members) { member in
                SessionDot(color: stateColor(member.mood),
                           icon: stateIcon(member.mood),
                           active: member.id == controller.activeMemberID) {
                    controller.focusSession(member.id)
                }
            }
            if controller.rosterOverflow > 0 {
                Text("+\(controller.rosterOverflow)")
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white.opacity(0.7))
                    .floatGlow(.black)
                    .onTapGesture { controller.cycleOverflow() }
            }
        }
        .frame(height: CompanionController.dotsRowHeight)
    }

    // MARK: 当前会话的"说话"（无盒子，全靠飘字 + 发光图标）

    @ViewBuilder private func speech(for member: CompanionMember) -> some View {
        let c = stateColor(member.mood)
        switch member.state {
        case .working:
            HStack(spacing: 6) {
                name(member.title, c)
                Text(L("干活中")).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).floatGlow(c)
                PulsingDots(color: c)
            }
        case let .done(reply):
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(c).floatGlow(c)
                    name(member.title, c)
                }
                Text((reply?.isEmpty == false) ? reply! : L("跑完了"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).floatGlow(c)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 210)
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.jump(to: member) }
        case let .needsApproval(request, _):
            VStack(spacing: 5) {
                name(member.title, c)
                if let body = FeedPresentation.body(for: request), !body.isEmpty {
                    Text(body).font(.system(size: 11.5).monospaced()).foregroundStyle(.white).floatGlow(c)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
                } else {
                    Text(FeedPresentation.title(for: request))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white).floatGlow(c)
                }
                approvalGlyphs(for: member, request: request)
            }
        }
    }

    @ViewBuilder private func approvalGlyphs(for member: CompanionMember, request: FeedRequest) -> some View {
        if controller.config.inlineApproval {
            HStack(spacing: 18) {
                glyphButton("checkmark.circle.fill", AppStyle.doneGreen) {
                    controller.resolve(.allow(.once), for: member)
                }
                glyphButton("xmark.circle.fill", AppStyle.errorRed) {
                    controller.resolve(.deny(.once), for: member)
                }
                if CompanionApproval.compact(for: request).hasMore {
                    glyphButton("ellipsis.circle.fill", .white.opacity(0.65), size: 20) {
                        controller.jump(to: member)
                    }
                }
            }
            .padding(.top, 1)
        } else {
            Text(L("去处理 →")).font(.system(size: 11, weight: .bold))
                .foregroundStyle(stateColor(member.mood)).floatGlow(stateColor(member.mood))
                .onTapGesture { controller.jump(to: member) }
        }
    }

    private func name(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .heavy)).foregroundStyle(c).floatGlow(c)
            .lineLimit(1)
    }

    private func glyphButton(_ symbol: String, _ c: Color, size: CGFloat = 26,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .bold)).foregroundStyle(c)
                .shadow(color: c.opacity(0.8), radius: 9).shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    private enum AuraItem: Identifiable {
        case dots
        case speech(CompanionMember)
        case quip(String)
        var id: String {
            switch self {
            case .dots: return "dots"
            case let .speech(m): return "speech:\(m.id)"
            case .quip: return "quip"
            }
        }
    }
}

// MARK: - 状态色 / 图标（成熟主题色，不发闷玻璃）

@MainActor private func stateColor(_ mood: PetMood) -> Color {
    switch mood {
    case .thinking: return AppStyle.accent
    case .needsYou: return AppStyle.waitAmber
    case .celebrating: return AppStyle.doneGreen
    case .sad: return AppStyle.errorRed
    case .idle: return AppStyle.accent
    case .sleeping: return Color(white: 0.6)
    }
}

private func stateIcon(_ mood: PetMood) -> String {
    switch mood {
    case .thinking: return "bolt.fill"
    case .needsYou: return "exclamationmark"
    case .celebrating: return "checkmark"
    case .sad: return "xmark"
    case .idle, .sleeping: return "circle.fill"
    }
}

/// 队长辉光浓淡：要你理时最亮，打盹时几乎无光。
private func glowStrength(_ mood: PetMood) -> Double {
    switch mood {
    case .needsYou: return 0.85
    case .celebrating, .sad: return 0.7
    case .thinking: return 0.6
    case .idle: return 0.4
    case .sleeping: return 0.0
    }
}

// MARK: - 飘字辉光（无盒子的可读性：黑描边感 + 同色辉光）

private struct FloatGlow: ViewModifier {
    var glow: Color
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
            .shadow(color: glow.opacity(0.55), radius: 8)
    }
}
private extension View {
    func floatGlow(_ glow: Color) -> some View { modifier(FloatGlow(glow: glow)) }
}

// MARK: - 会话光点（一会话一点；active 更大更亮 + 状态图标 + 描边环）

private struct SessionDot: View {
    let color: Color
    let icon: String
    let active: Bool
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle().fill(color)
                    .frame(width: active ? 17 : 12, height: active ? 17 : 12)
                    .shadow(color: color, radius: active ? 8 : 4)
                if active {
                    Image(systemName: icon).font(.system(size: 8, weight: .black)).foregroundStyle(.white)
                    Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).frame(width: 23, height: 23)
                }
            }
            .frame(width: 26, height: 26)              // 点选命中区
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 干活时飘字旁的呼吸点（仅当前会话一处，开销可忽略）。
private struct PulsingDots: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 4, height: 4)
                        .opacity(0.35 + 0.65 * pulse(t, i))
                        .shadow(color: color, radius: 3)
                }
            }
        }
    }
    private func pulse(_ t: Double, _ i: Int) -> Double {
        (sin(t * 3 - Double(i) * 0.7) + 1) / 2
    }
}

// MARK: - 精灵本体（程序化，模版定形状/配色，PetMood 定表情）

/// 一只随心情变表情的小生物：身体形状 + 配色由 `PetTemplate` 决定；
/// 弹跳/眨眼/嘴形/头顶小标由 `PetMood` 决定（保证任何模版下状态都一眼可读）。
struct PetSprite: View {
    let mood: PetMood
    var template: PetTemplate = PetTemplateCatalog.default
    /// false = 静态单帧（无 TimelineView）。设置里的模版列表用它，避免一排宠物同时跑动画卡顿。
    var animated = true

    private static let slate = Color(red: 0.27, green: 0.29, blue: 0.34)

    private var bodyColor: Color { Color(hex: template.bodyHex) ?? Color(white: 0.96) }
    private var cheekColor: Color { Color(hex: template.cheekHex) ?? tint.opacity(0.3) }

    private var bodyShape: AnyShape {
        switch template.shape {
        case .blob: return AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .round: return AnyShape(Ellipse())
        case .square: return AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    var body: some View {
        if animated {
            TimelineView(.animation) { timeline in
                sprite(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            sprite(phase: 0)        // 静态帧：bob=0、睁眼
        }
    }

    private func sprite(phase t: TimeInterval) -> some View {
        let bob = bobOffset(t)
        let eyesClosed = (mood == .sleeping) || (mood == .sad) || isBlinking(t)
        return ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.16))
                .frame(width: 50, height: 10)
                .offset(y: 40)
                .blur(radius: 3)

            ZStack {
                bodyShape
                    .fill(bodyColor)
                    .overlay(bodyShape.stroke(tint.opacity(0.95), lineWidth: 3))
                    .frame(width: 66, height: 60)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)

                HStack(spacing: 30) {
                    Circle().fill(cheekColor.opacity(0.55)).frame(width: 8, height: 8)
                    Circle().fill(cheekColor.opacity(0.55)).frame(width: 8, height: 8)
                }
                .offset(y: 6)

                HStack(spacing: 18) {
                    Eye(closed: eyesClosed, color: Self.slate)
                    Eye(closed: eyesClosed, color: Self.slate)
                }
                .offset(y: -4)

                Mouth(mood: mood)
                    .stroke(Self.slate, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 9)
                    .offset(y: 15)
            }
            .offset(y: bob)

            if let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(badge.color))
                    .offset(y: -34 + bob * 0.6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 84, height: 84)
    }

    private func bobOffset(_ t: TimeInterval) -> CGFloat {
        switch mood {
        case .sleeping: return 0
        case .celebrating: return -abs(sin(t * 6)) * 8
        case .needsYou: return sin(t * 5) * 3
        case .thinking: return sin(t * 2.2) * 2
        default: return sin(t * 1.6) * 2
        }
    }

    private func isBlinking(_ t: TimeInterval) -> Bool {
        let cycle = t.truncatingRemainder(dividingBy: 3.4)
        return cycle > 3.25
    }

    private var tint: Color {
        switch mood {
        case .idle, .thinking: return AppStyle.accent
        case .needsYou: return Color(red: 0.91, green: 0.62, blue: 0.20)
        case .celebrating: return Color(red: 0.27, green: 0.69, blue: 0.42)
        case .sad: return Color(red: 0.82, green: 0.38, blue: 0.46)
        case .sleeping: return Color(red: 0.56, green: 0.58, blue: 0.64)
        }
    }

    private var badge: (symbol: String, color: Color)? {
        switch mood {
        case .thinking: return ("ellipsis", AppStyle.accent)
        case .needsYou: return ("exclamationmark", Color(red: 0.91, green: 0.55, blue: 0.15))
        case .celebrating: return ("sparkles", Color(red: 0.24, green: 0.66, blue: 0.40))
        case .sleeping: return ("zzz", Color(red: 0.56, green: 0.58, blue: 0.64))
        case .sad, .idle: return nil
        }
    }
}

private struct Eye: View {
    let closed: Bool
    let color: Color
    var body: some View {
        Group {
            if closed {
                Capsule().fill(color).frame(width: 9, height: 2.4)
            } else {
                Capsule().fill(color).frame(width: 7, height: 9)
            }
        }
        .animation(.easeInOut(duration: 0.08), value: closed)
    }
}

private struct Mouth: Shape {
    let mood: PetMood
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midY = rect.midY
        switch mood {
        case .celebrating:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                           control: CGPoint(x: rect.midX, y: rect.maxY + 2))
        case .needsYou:
            p.addEllipse(in: CGRect(x: rect.midX - 3, y: midY - 3, width: 6, height: 6))
        case .sad:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                           control: CGPoint(x: rect.midX, y: rect.minY))
        case .sleeping:
            p.move(to: CGPoint(x: rect.midX - 3, y: midY))
            p.addLine(to: CGPoint(x: rect.midX + 3, y: midY))
        default:
            p.move(to: CGPoint(x: rect.minX + 2, y: midY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - 2, y: midY),
                           control: CGPoint(x: rect.midX, y: midY + 3))
        }
        return p
    }
}

import SwiftUI

/// 状态栏铃铛：有未读时亮 accent 并带角标，点击弹出最近完成列表。
struct ActivityBellView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var log: AgentActivityLog
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
            if showing { log.markSeen() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: log.unseenCount > 0 ? "bell.badge.fill" : "bell")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(log.unseenCount > 0 ? AppStyle.accent : AppStyle.textTertiary)
                    .symbolRenderingMode(.hierarchical)
                if log.unseenCount > 0 {
                    Text("\(log.unseenCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(height: 13)
                        .background(Capsule().fill(AppStyle.accent))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Agent 完成记录"))
        .popover(isPresented: $showing, arrowEdge: .top) {
            ActivityCenterView(coordinator: coordinator, log: log) { showing = false }
        }
    }
}

/// 通知中心：最近完成的 agent 任务，按天分组、相对时间显示。
/// 点击条目跳到对应 pane 并闪边框定位；已关闭的终端置灰不可跳。
struct ActivityCenterView: View {
    let coordinator: AppCoordinator
    @ObservedObject var log: AgentActivityLog
    let onClose: () -> Void

    /// 按自然日分组（今天 / 昨天 / 具体日期），组内保持新→旧。
    private var grouped: [(label: String, items: [AgentActivityEntry])] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [AgentActivityEntry]] = [:]
        for entry in log.entries {
            let day = cal.startOfDay(for: entry.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { (Self.dayLabel($0, calendar: cal), buckets[$0] ?? []) }
    }

    static func dayLabel(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return L("今天") }
        if calendar.isDateInYesterday(day) { return L("昨天") }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Agent 完成记录"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.textPrimary)
                Spacer()
                if !log.entries.isEmpty {
                    ToolActionButton(
                        title: L("清空"),
                        role: .secondary,
                        height: 23,
                        fontSize: 10.5,
                        horizontalPadding: 9) {
                            log.clear()
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if log.entries.isEmpty {
                ToolEmptyState(
                    icon: "bell.slash",
                    title: L("还没有完成记录"),
                    detail: L("Agent 跑完任务会记在这里。"),
                    compact: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                // 30 秒滴答一次，让「x 分钟前」在面板开着时也保持新鲜
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                            ForEach(grouped, id: \.label) { group in
                                Text(group.label)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(AppStyle.textTertiary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(group.items) { entry in
                                    ActivityRow(
                                        entry: entry,
                                        alive: entry.paneID.map { coordinator.paneExists($0) } ?? false,
                                        now: context.date,
                                        onTap: {
                                            onClose()
                                            if let pane = entry.paneID {
                                                coordinator.revealPane(pane)
                                            }
                                        },
                                        onDelete: {
                                            withAnimation(Motion.snappy) { log.remove(entry.id) }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 320)
                }
            }
        }
        .frame(width: 320)
        .background(AppStyle.windowBackground)
    }
}

private struct ActivityRow: View {
    let entry: AgentActivityEntry
    /// 目标 pane 还活着吗？关掉的置灰、不可点跳转。
    let alive: Bool
    let now: Date
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { if alive { onTap() } }) {
            HStack(alignment: .top, spacing: 9) {
                logo
                    .saturation(alive ? 1 : 0)
                    .opacity(alive ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(alive ? AppStyle.textPrimary : AppStyle.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // hover 时相对时间换成单条删除 ✕（死条目也能删）
                        ZStack(alignment: .trailing) {
                            Text(Self.relativeText(entry.date, now: now))
                                .font(.system(size: 9.5))
                                .monospacedDigit()
                                .foregroundStyle(AppStyle.textTertiary)
                                .opacity(hovering ? 0 : 1)
                            if hovering {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.textTertiary)
                                    .contentShape(Rectangle())
                                    .onTapGesture(perform: onDelete)
                                    .help(L("删除这条记录"))
                                    .transition(.opacity)
                            }
                        }
                    }
                    if !entry.message.isEmpty {
                        Text(entry.message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(alive ? AppStyle.textSecondary : AppStyle.textTertiary.opacity(0.8))
                            .lineLimit(2)
                    }
                    if let duration = entry.duration {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.system(size: 8, weight: .semibold))
                            Text(AgentActivityEntry.durationText(duration))
                                .font(.system(size: 9.5, weight: .medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(alive ? AppStyle.accent.opacity(0.9) : AppStyle.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppStyle.hoverFill))
                        .padding(.top, 1)
                        .help(L("本轮思考用时"))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && alive ? AppStyle.hoverFill : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(alive ? L("点击跳到该终端") : L("该终端已关闭"))
    }

    /// 一分钟内显示「刚刚」，其余交给系统相对时间（跟随应用语言）。
    static func relativeText(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return L("刚刚") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    @ViewBuilder
    private var logo: some View {
        if let agentID = entry.agentID, let image = CLIToolLogo.image(named: agentID) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: 15, height: 15)
                .padding(.top, 1)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(alive ? AppStyle.accent : AppStyle.textTertiary)
                .padding(.top, 1)
        }
    }
}

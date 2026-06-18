import ConductorCore
import SwiftUI

/// Token 用量仪表盘：扫描 Claude / Codex 会话日志，按天 / 模型 / 项目聚合 token 与估算成本。
struct UsageStatsView: View {
    var onOpenManagement: () -> Void = {}
    /// 主题变 → 重渲染（AppStyle 跟随）。不观察的话切主题后停在旧配色。
    @ObservedObject private var configStore = ConfigStore.shared
    @State private var report: UsageReport?
    @State private var loading = false
    @State private var daysBack = 30
    @State private var selectedDay: String?
    /// 按 CLI 过滤（nil = 全部）。所有区块跟随。
    @State private var sourceFilter: UsageSource?

    private static let claudeColor = Color(red: 0.85, green: 0.45, blue: 0.18)
    private static let codexColor = Color(red: 0.22, green: 0.62, blue: 0.40)

    static func color(for source: UsageSource) -> Color {
        source == .claude ? claudeColor : codexColor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rangePicker
                if loading && report == nil {
                    loadingRow
                } else if let report {
                    sourcePicker(report)
                    summaryTiles(report)
                    if !report.byDay.isEmpty { dailyChart(report) }
                    tokenComposition(report)
                    if sourceFilter == nil { sourceBreakdown(report) }
                    projectSection(report)
                    modelTable(report)
                    footnote(report)
                } else {
                    emptyRow
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .onAppear { if report == nil { reload() } }
    }

    // MARK: - 按 CLI 过滤

    /// 当前过滤下的区间合计。
    private func filteredGrand(_ r: UsageReport) -> UsageTotals {
        sourceFilter.flatMap { r.bySource[$0] } ?? r.grand
    }

    /// 当前过滤下某天的合计。
    private func filteredDay(_ d: DailyUsage) -> UsageTotals {
        sourceFilter.flatMap { d.bySource[$0] ?? UsageTotals() } ?? d.totals
    }

    private func filteredSessions(_ r: UsageReport) -> Int {
        sourceFilter.flatMap { r.sessionsBySource[$0] } ?? r.sessionsScanned
    }

    private func sourcePicker(_ r: UsageReport) -> some View {
        HStack(spacing: 5) {
            sourceChip(nil, label: L("全部"), cost: r.grand.costUSD)
            ForEach(UsageSource.allCases, id: \.self) { src in
                sourceChip(src, label: src.displayName, cost: r.bySource[src]?.costUSD ?? 0)
            }
            Spacer()
        }
    }

    private func sourceChip(_ src: UsageSource?, label: String, cost: Double) -> some View {
        let selected = sourceFilter == src
        return Button {
            sourceFilter = src
            selectedDay = nil
        } label: {
            HStack(spacing: 4) {
                if let src {
                    Circle().fill(Self.color(for: src)).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                Text("$" + UsageNumber.money(cost))
                    .font(.system(size: 9.5, weight: .medium))
                    .opacity(0.75)
            }
            .foregroundStyle(selected ? AppStyle.theme.primarySolidText : AppStyle.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(selected ? AppStyle.accent : AppStyle.hoverFill))
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: - 区间选择

    private var rangePicker: some View {
        HStack(spacing: 8) {
            Text(L("Token 用量"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppStyle.textPrimary)
            IconOnlyButton(
                systemName: "rectangle.3.group",
                help: L("打开用量管理"),
                size: 24,
                symbolSize: 10.5,
                tint: AppStyle.textTertiary,
                action: onOpenManagement)
            Spacer()
            ForEach([7, 30, 90], id: \.self) { d in
                Button { daysBack = d; selectedDay = nil; reload() } label: {
                    Text(L("%ld天", d))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(daysBack == d ? AppStyle.theme.primarySolidText : AppStyle.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(daysBack == d ? AppStyle.accent : AppStyle.hoverFill))
                }
                .buttonStyle(PressScaleStyle())
            }
            IconOnlyButton(
                systemName: "arrow.clockwise",
                help: L("刷新用量统计"),
                size: 24,
                symbolSize: 11,
                weight: .bold,
                tint: AppStyle.textSecondary,
                action: reload)
            .disabled(loading)
        }
    }

    // MARK: - 概览（含今日）

    private func summaryTiles(_ r: UsageReport) -> some View {
        let grand = filteredGrand(r)
        let today = Self.todayString()
        let todayUsage = r.byDay.first { $0.day == today }.map(filteredDay) ?? UsageTotals()
        let activeDays = r.byDay.filter { filteredDay($0).totalTokens > 0 }.count
        let avg = activeDays == 0 ? 0 : grand.costUSD / Double(activeDays)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                statTile(L("今日成本"), "$" + UsageNumber.money(todayUsage.costUSD),
                         sub: "\(UsageNumber.compact(todayUsage.totalTokens)) tok", highlight: true)
                statTile(L("%ld天成本", daysBack), "$" + UsageNumber.money(grand.costUSD),
                         sub: L("日均 $%@", UsageNumber.money(avg)))
            }
            HStack(spacing: 10) {
                statTile(L("总 Token"), UsageNumber.compact(grand.totalTokens),
                         sub: L("输出 %@", UsageNumber.compact(grand.outputTokens)))
                statTile(L("会话数"), "\(filteredSessions(r))",
                         sub: L("活跃 %ld 天", activeDays))
            }
        }
    }

    private func statTile(_ label: String, _ value: String, sub: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(highlight ? AppStyle.accent : AppStyle.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
            Text(sub)
                .font(.system(size: 9.5))
                .foregroundStyle(AppStyle.textTertiary.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .toolsCard()
    }

    // MARK: - 每日堆叠柱状（按来源，可点选）

    private func dailyChart(_ r: UsageReport) -> some View {
        let days = filledDays(r)
        let maxCost = max(days.map { filteredDay($0).costUSD }.max() ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L("每日成本"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppStyle.textSecondary)
                if let f = sourceFilter {
                    legendDot(Self.color(for: f), f.displayName)
                } else {
                    legendDot(Self.claudeColor, "Claude")
                    legendDot(Self.codexColor, "Codex")
                }
                Spacer()
                if selectedDay != nil {
                    Button { selectedDay = nil } label: {
                        Text(L("取消选中"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .bottom, spacing: days.count > 45 ? 1 : 2) {
                ForEach(days) { day in
                    dayBar(day, maxCost: maxCost)
                }
            }
            .frame(height: 96, alignment: .bottom)
            HStack {
                Text(shortDay(days.first?.day ?? ""))
                Spacer()
                Text(shortDay(days.last?.day ?? ""))
            }
            .font(.system(size: 9))
            .foregroundStyle(AppStyle.textTertiary)

            if let sel = selectedDay, let day = r.byDay.first(where: { $0.day == sel }) {
                dayDetail(day)
            }
        }
        .padding(12)
        .toolsCard()
    }

    private func dayBar(_ day: DailyUsage, maxCost: Double) -> some View {
        let claudeCost = sourceFilter == nil || sourceFilter == .claude
            ? (day.bySource[.claude]?.costUSD ?? 0) : 0
        let codexCost = sourceFilter == nil || sourceFilter == .codex
            ? (day.bySource[.codex]?.costUSD ?? 0) : 0
        let dayTotals = filteredDay(day)
        let scale = 88.0 / maxCost
        let isSelected = selectedDay == day.day
        let dimmed = selectedDay != nil && !isSelected
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Self.codexColor)
                .frame(height: max(codexCost * scale, codexCost > 0 ? 1.5 : 0))
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Self.claudeColor)
                .frame(height: max(claudeCost * scale, claudeCost > 0 ? 1.5 : 0))
            if dayTotals.costUSD == 0 {
                Circle()
                    .fill(AppStyle.textTertiary.opacity(0.35))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle().inset(by: -4))
        .onTapGesture { selectedDay = isSelected ? nil : day.day }
        .help("\(day.day)  $\(UsageNumber.money(dayTotals.costUSD))  ·  \(UsageNumber.compact(dayTotals.totalTokens)) tok")
    }

    private func dayDetail(_ day: DailyUsage) -> some View {
        let c = day.bySource[.claude] ?? UsageTotals()
        let x = day.bySource[.codex] ?? UsageTotals()
        let total = filteredDay(day)
        return VStack(alignment: .leading, spacing: 4) {
            Text(day.day)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(AppStyle.textPrimary)
            HStack(spacing: 14) {
                detailItem(L("合计"), "$" + UsageNumber.money(total.costUSD),
                           UsageNumber.compact(total.totalTokens) + " tok")
                if sourceFilter == nil || sourceFilter == .claude {
                    detailItem("Claude", "$" + UsageNumber.money(c.costUSD),
                               UsageNumber.compact(c.totalTokens) + " tok", color: Self.claudeColor)
                }
                if sourceFilter == nil || sourceFilter == .codex {
                    detailItem("Codex", "$" + UsageNumber.money(x.costUSD),
                               UsageNumber.compact(x.totalTokens) + " tok", color: Self.codexColor)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppStyle.hoverFill))
    }

    private func detailItem(_ label: String, _ value: String, _ sub: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(AppStyle.textTertiary)
            }
            Text(value).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(AppStyle.textPrimary)
            Text(sub).font(.system(size: 9)).foregroundStyle(AppStyle.textTertiary)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 9.5)).foregroundStyle(AppStyle.textTertiary)
        }
    }

    /// 把日期序列补满（无数据的天补 0），柱状图才有正确的时间轴。
    private func filledDays(_ r: UsageReport) -> [DailyUsage] {
        guard let first = r.byDay.first?.day, let last = r.byDay.last?.day,
              let start = Self.parseDay(first), let end = Self.parseDay(last) else { return r.byDay }
        let known = Dictionary(uniqueKeysWithValues: r.byDay.map { ($0.day, $0) })
        var out: [DailyUsage] = []
        var cur = start
        let cal = Calendar.current
        while cur <= end {
            let key = Self.dayString(cur)
            out.append(known[key] ?? DailyUsage(day: key, totals: UsageTotals(), bySource: [:]))
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    // MARK: - Token 构成

    private func tokenComposition(_ r: UsageReport) -> some View {
        let g = filteredGrand(r)
        let parts: [(String, Int, Color)] = [
            (L("输入"), g.inputTokens, .blue),
            (L("输出"), g.outputTokens, .purple),
            (L("缓存写"), g.cacheCreationTokens, .teal),
            (L("缓存读"), g.cacheReadTokens, AppStyle.textTertiary.opacity(0.55)),
        ]
        let total = max(g.totalTokens, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Token 构成"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppStyle.textSecondary)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle()
                            .fill(part.2)
                            .frame(width: max(geo.size.width * CGFloat(part.1) / CGFloat(total), part.1 > 0 ? 2 : 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 3) {
                        Circle().fill(part.2).frame(width: 6, height: 6)
                        Text("\(part.0) \(UsageNumber.compact(part.1))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                }
            }
        }
        .padding(12)
        .toolsCard()
    }

    // MARK: - 按来源

    private func sourceBreakdown(_ r: UsageReport) -> some View {
        HStack(spacing: 10) {
            ForEach(UsageSource.allCases, id: \.self) { src in
                let t = r.bySource[src] ?? UsageTotals()
                let share = r.grand.costUSD > 0 ? t.costUSD / r.grand.costUSD : 0
                Button {
                    sourceFilter = src
                    selectedDay = nil
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(Self.color(for: src))
                                .frame(width: 7, height: 7)
                            Text(src.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppStyle.textPrimary)
                            Spacer()
                            Text(String(format: "%.0f%%", share * 100))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(AppStyle.textTertiary)
                        }
                        Text("$" + UsageNumber.money(t.costUSD))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(AppStyle.accent)
                        Text(L("%1$@ tok · %2$ld 会话", UsageNumber.compact(t.totalTokens), r.sessionsBySource[src] ?? 0))
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(AppStyle.hoverFill))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(PressScaleStyle())
                .help(L("只看 %@", src.displayName))
            }
        }
    }

    // MARK: - 按项目

    private func projectSection(_ r: UsageReport) -> some View {
        // 过滤后取该 CLI 在各项目的份额，重新排序，藏掉为 0 的。
        let items: [(project: ProjectUsage, totals: UsageTotals)] = r.byProject
            .filter { !$0.path.isEmpty }
            .compactMap { p in
                let t = sourceFilter.flatMap { p.bySource[$0] } ?? p.totals
                return t.totalTokens > 0 ? (p, t) : nil
            }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
            .prefix(8)
            .map { $0 }
        let maxCost = max(items.map { $0.totals.costUSD }.max() ?? 0, 0.0001)
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ToolsSectionLabel(L("按项目"))
                    ForEach(items, id: \.project.id) { item in
                        projectRow(item.project, totals: item.totals, maxCost: maxCost)
                    }
                }
            }
        }
    }

    private func projectRow(_ p: ProjectUsage, totals: UsageTotals, maxCost: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(AppStyle.textTertiary)
                Text(Self.shortPath(p.path))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppStyle.textPrimary)
                    .lineLimit(1).truncationMode(.head)
                    .help(p.path)
                Spacer()
                Text(UsageNumber.compact(totals.totalTokens) + " tok")
                    .font(.system(size: 9.5))
                    .foregroundStyle(AppStyle.textTertiary)
                Text("$" + UsageNumber.money(totals.costUSD))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppStyle.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            // 占比条：全部视图按来源双色堆叠；过滤后单色。
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(UsageSource.allCases, id: \.self) { src in
                        if sourceFilter == nil || sourceFilter == src {
                            let cost = sourceFilter == nil
                                ? (p.bySource[src]?.costUSD ?? 0) : totals.costUSD
                            Rectangle()
                                .fill(Self.color(for: src).opacity(0.75))
                                .frame(width: max(geo.size.width * CGFloat(cost / maxCost), cost > 0 ? 2 : 0))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppStyle.hoverFill.opacity(0.5)))
    }

    // MARK: - 按模型

    private func modelTable(_ r: UsageReport) -> some View {
        let models = sourceFilter.map { f in r.byModel.filter { $0.source == f } } ?? r.byModel
        let grandCost = filteredGrand(r).costUSD
        let maxCost = max(models.map { $0.totals.costUSD }.max() ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 6) {
            ToolsSectionLabel(L("按模型"))
            ForEach(models) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(m.source == .claude ? Self.claudeColor : Self.codexColor)
                            .frame(width: 7, height: 7)
                        Text(m.model)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppStyle.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.0f%%", grandCost > 0 ? m.totals.costUSD / grandCost * 100 : 0))
                            .font(.system(size: 9.5))
                            .foregroundStyle(AppStyle.textTertiary)
                        Text("$" + UsageNumber.money(m.totals.costUSD))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppStyle.textPrimary)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill((m.source == .claude ? Self.claudeColor : Self.codexColor).opacity(0.7))
                            .frame(width: max(geo.size.width * CGFloat(m.totals.costUSD / maxCost), 2))
                    }
                    .frame(height: 4)
                    Text("in \(UsageNumber.compact(m.totals.inputTokens)) · out \(UsageNumber.compact(m.totals.outputTokens)) · cache \(UsageNumber.compact(m.totals.cacheReadTokens + m.totals.cacheCreationTokens))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppStyle.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppStyle.hoverFill.opacity(0.5)))
            }
        }
    }

    private func footnote(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(loading ? L("更新中…") : L("更新于 %@", UsageRelative.text(r.generatedAt)))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppStyle.textTertiary)
            Text(L("成本按公开价目表估算，第三方代理/订阅实际计费可能不同。数据来自本机会话记录。"))
                .font(.system(size: 9.5))
                .foregroundStyle(AppStyle.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("正在读取本机会话…")).font(.system(size: 12)).foregroundStyle(AppStyle.textSecondary)
            Spacer()
        }.padding(.vertical, 20)
    }

    private var emptyRow: some View {
        ToolEmptyState(
            icon: "chart.bar.xaxis",
            title: L("没有找到用量数据"),
            compact: true)
        .padding(.top, 8)
    }

    // MARK: - 加载

    private func reload() {
        let days = daysBack
        // 先显示缓存（秒开），再后台重扫更新。
        if let cached = UsageReportStore.load(daysBack: days) {
            report = cached
        } else {
            report = nil
        }
        loading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> UsageReport in
                UsageScanner().scan(daysBack: days)
            }.value
            UsageReportStore.save(result, daysBack: days)
            await MainActor.run {
                if daysBack == days {
                    report = result
                    loading = false
                }
            }
        }
    }

    // MARK: - 日期工具

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func todayString() -> String { dayFormatter.string(from: Date()) }
    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func parseDay(_ s: String) -> Date? { dayFormatter.date(from: s) }

    /// 把绝对路径缩短为 `~/…/last/two`。
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/")
        if parts.count > 3 {
            return (p.hasPrefix("~") ? "~/…/" : "/…/") + parts.suffix(2).joined(separator: "/")
        }
        return p
    }

    private func shortDay(_ day: String) -> String {
        day.count == 10 ? String(day.dropFirst(5)) : day   // MM-dd
    }
}

/// 数字格式化（紧凑 token 数 + 金额）。
enum UsageNumber {
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(n)"
    }

    static func money(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }
}

enum UsageRelative {
    static func text(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return L("刚刚") }
        if s < 3600 { return L("%ld 分钟前", s / 60) }
        if s < 86400 { return L("%ld 小时前", s / 3600) }
        return L("%ld 天前", s / 86400)
    }
}

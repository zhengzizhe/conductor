import Charts
import SwiftUI

/// provider 用量趋势图：用本地累积的采样画。compact 为内嵌小图（无坐标轴），
/// 否则为展开大图（带时间轴 + 多窗折线 / 消费曲线）。
struct UsageTrendChart: View {
    let samples: [UsageSample]
    var compact = true
    @ObservedObject private var configStore = ConfigStore.shared

    /// 是否以百分比为主指标（任一采样有窗口百分比）。否则画消费金额。
    private var isPercent: Bool { self.samples.contains { $0.primaryPercent != nil } }

    private var accent: Color { AppStyle.accent }

    var body: some View {
        if self.samples.count < 2 {
            Text(L("趋势积累中…"))
                .font(.system(size: 10)).foregroundStyle(AppStyle.textTertiary)
                .padding(.leading, 44).padding(.top, 4)
        } else if self.compact {
            self.chart
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 40)
                .padding(.leading, 44).padding(.top, 6).padding(.trailing, 2)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                self.chart
                    .chartYAxis {
                        AxisMarks(position: .leading) { AxisValueLabel().font(.system(size: 8)) }
                    }
                    .chartXAxis {
                        AxisMarks { AxisValueLabel(format: .dateTime.month().day()).font(.system(size: 8)) }
                    }
                    .frame(height: 120)
                Text(self.footnote)
                    .font(.system(size: 9.5)).foregroundStyle(AppStyle.textTertiary)
            }
            .padding(.leading, 44).padding(.top, 6).padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private var chart: some View {
        if self.isPercent {
            Chart {
                ForEach(Array(self.samples.enumerated()), id: \.offset) { _, s in
                    if let p = s.primaryPercent {
                        AreaMark(x: .value("t", s.at), y: .value("used", p),
                                 series: .value("w", L("主")))
                            .foregroundStyle(self.accent.opacity(0.18))
                        LineMark(x: .value("t", s.at), y: .value("used", p),
                                 series: .value("w", L("主")))
                            .foregroundStyle(self.accent)
                            .interpolationMethod(.monotone)
                    }
                    // 展开模式才叠加次/三窗折线，避免小图杂乱。
                    if !self.compact, let p = s.secondaryPercent {
                        LineMark(x: .value("t", s.at), y: .value("used", p),
                                 series: .value("w", L("次")))
                            .foregroundStyle(AppStyle.waitAmber)
                            .interpolationMethod(.monotone)
                    }
                    if !self.compact, let p = s.tertiaryPercent {
                        LineMark(x: .value("t", s.at), y: .value("used", p),
                                 series: .value("w", L("三")))
                            .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 0.85))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0 ... 100)
        } else {
            Chart {
                ForEach(Array(self.samples.enumerated()), id: \.offset) { _, s in
                    if let c = s.costUsed {
                        AreaMark(x: .value("t", s.at), y: .value("cost", c))
                            .foregroundStyle(self.accent.opacity(0.18))
                        LineMark(x: .value("t", s.at), y: .value("cost", c))
                            .foregroundStyle(self.accent)
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
    }

    /// 展开图脚注：指标说明 + 当前值。
    private var footnote: String {
        guard let last = samples.last else { return "" }
        if self.isPercent {
            let p = Int((last.primaryPercent ?? 0).rounded())
            return L("主窗已用 %ld%% · 共 %ld 个采样点", p, self.samples.count)
        }
        let cur = last.currency ?? "USD"
        return L("消费 %@ %.2f · 共 %ld 个采样点", cur, last.costUsed ?? 0, self.samples.count)
    }
}

import Charts
import SwiftUI

struct UsageSample: Identifiable {
    let date: Date
    /// Sum of %CPU over the dev processes (100 = one full core).
    let cpu: Double
    /// Sum of memory in MB.
    let memory: Double

    var id: Date { date }
}

enum UsageFormat {
    static func cpu(_ value: Double) -> String { "\(String(Int(value.rounded())))%" }

    static func memory(_ megabytes: Double) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : "\(String(Int(megabytes))) MB"
    }
}

/// Small header with CPU and memory sparklines for the last few minutes.
struct UsageHeader: View {
    let samples: [UsageSample]
    let processes: [ListeningProcess]
    let colorSlots: ColorSlots
    let showGraphs: Bool
    let showBreakdown: Bool
    /// A process clicked in Top consumers, by id: people click the name of what's using too much
    /// expecting to get to it, so its row opens.
    var onSelect: (String) -> Void = { _ in }

    /// Docker container rows share the backend's pid and carry no usage, so count each pid once.
    private var processCount: Int { Set(processes.map(\.pid)).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showGraphs {
                HStack(spacing: 12) {
                    UsageChart(title: "CPU", samples: samples, value: \.cpu, format: UsageFormat.cpu)
                    UsageChart(title: "Memory", samples: samples, value: \.memory, format: UsageFormat.memory)
                }
            }
            if showBreakdown {
                UsageBreakdown(processes: processes, colorSlots: colorSlots, onSelect: onSelect)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var windowMinutes: Int {
        guard let first = samples.first?.date else { return 0 }
        return max(1, Int(Date().timeIntervalSince(first) / 60))
    }
}

struct UsageChart: View {
    let title: String
    let samples: [UsageSample]
    let value: KeyPath<UsageSample, Double>
    let format: (Double) -> String

    @State private var hovered: UsageSample?

    private var shown: UsageSample? { hovered ?? samples.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let hovered {
                    Text(hovered.date, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: shown.map { format($0[keyPath: value]) } ?? "–")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Chart {
                ForEach(samples) { sample in
                    AreaMark(x: .value("Time", sample.date), y: .value(title, sample[keyPath: value]))
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.date), y: .value(title, sample[keyPath: value]))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if let hovered {
                    RuleMark(x: .value("Time", hovered.date))
                        .foregroundStyle(.tertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", hovered.date), y: .value(title, hovered[keyPath: value]))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(40)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(yMax, 1))
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geo[plot].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    hovered = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 38)
        }
        .padding(8)
        .panelBackground(.quinary)
    }

    /// Headroom above the peak so the line never touches the top edge.
    private var yMax: Double {
        (samples.map { $0[keyPath: value] }.max() ?? 0) * 1.2
    }
}

/// Categorical palette (fixed order, validated for adjacent pairs in light and dark).
enum SeriesPalette {
    private static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4]
    private static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181]
    static let count = light.count

    static func color(slot: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: (isDark ? dark : light)[slot % count])
        })
    }

    static let other = Color.secondary.opacity(0.5)
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Keeps each process on the same color while it stays in the top list, even when ranks change.
final class ColorSlots {
    private var slots: [String: Int] = [:]

    func assign(_ keys: [String]) -> [String: Int] {
        let wanted = Set(keys)
        slots = slots.filter { wanted.contains($0.key) }
        for key in keys where slots[key] == nil {
            let used = Set(slots.values)
            slots[key] = (0..<SeriesPalette.count).first { !used.contains($0) } ?? 0
        }
        return slots
    }
}

struct UsageSlice: Identifiable {
    let id: String
    let title: String
    let value: Double
    let color: Color
}

/// Donut of which processes use the most memory or CPU right now.
struct UsageBreakdown: View {
    enum Metric: String, CaseIterable { case memory = "Memory", cpu = "CPU" }

    let processes: [ListeningProcess]
    let colorSlots: ColorSlots
    var onSelect: (String) -> Void = { _ in }

    @AppStorage("servers.breakdownMetric") private var metric: Metric = .memory
    @State private var selectedAngle: Double?

    private func value(_ process: ListeningProcess) -> Double {
        (metric == .memory ? process.memory : process.cpu) ?? 0
    }

    private func format(_ value: Double) -> String {
        metric == .memory ? UsageFormat.memory(value) : UsageFormat.cpu(value)
    }

    private var slices: [UsageSlice] {
        let ranked = processes.filter { value($0) > 0 }.sorted { value($0) > value($1) }
        let top = Array(ranked.prefix(SeriesPalette.count))
        let slots = colorSlots.assign(top.map(\.id))
        var result = top.map {
            UsageSlice(id: $0.id, title: $0.title, value: value($0), color: SeriesPalette.color(slot: slots[$0.id] ?? 0))
        }
        let rest = ranked.dropFirst(SeriesPalette.count).map(value).reduce(0, +)
        if rest > 0 {
            result.append(UsageSlice(id: "other", title: "Other (\(String(ranked.count - top.count)))", value: rest, color: SeriesPalette.other))
        }
        return result
    }

    private func slice(at angle: Double?, in slices: [UsageSlice]) -> UsageSlice? {
        guard let angle else { return nil }
        var total = 0.0
        return slices.first { total += $0.value; return angle <= total }
    }

    var body: some View {
        let slices = slices
        let total = slices.map(\.value).reduce(0, +)
        let selected = slice(at: selectedAngle, in: slices)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if slices.isEmpty {
                // Padding rather than `minHeight`: a minimum height in the content becomes the panel's minimum.
                Text(metric == .cpu ? "No CPU usage right now" : "No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value("Usage", slice.value),
                            innerRadius: .ratio(0.62),
                            outerRadius: .ratio(selected == nil || selected?.id == slice.id ? 1 : 0.92),
                            angularInset: 1
                        )
                        .cornerRadius(2)
                        .foregroundStyle(slice.color)
                        .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.45)
                    }
                    .chartLegend(.hidden)
                    .chartAngleSelection(value: $selectedAngle)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            Text(verbatim: format(selected?.value ?? total))
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                            if let selected {
                                Text(verbatim: "\(String(Int((selected.value / total * 100).rounded())))%")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 86, height: 86)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(slices) { slice in
                            legendRow(slice, total: total, isSelected: selected?.id == slice.id)
                        }
                    }
                }
            }
        }
        .padding(8)
        .panelBackground(.quinary)
    }

    /// A process in the legend opens its row when clicked ("Other" lumps several, so it doesn't).
    /// Only its share is shown.
    @ViewBuilder private func legendRow(_ slice: UsageSlice, total: Double, isSelected: Bool) -> some View {
        let row = HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(slice.color)
                .frame(width: 8, height: 8)
            Text(verbatim: slice.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(verbatim: "\(String(Int((slice.value / total * 100).rounded())))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .font(.caption)
        .fontWeight(isSelected ? .semibold : .regular)
        .padding(.horizontal, 3)

        if slice.id == "other" {
            row
        } else {
            Button { onSelect(slice.id) } label: { row }
                .buttonStyle(.panel)
        }
    }
}

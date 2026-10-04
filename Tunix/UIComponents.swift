import SwiftUI

enum TunixDesign {
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 26
    static let groupSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    static let panelRadius: CGFloat = 14
    static let panelPadding: CGFloat = 20
    static let chartHeight: CGFloat = 156

    static var panelFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.74)
    }

    static var subtleFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.52)
    }

    static var panelStroke: Color {
        Color.primary.opacity(0.13)
    }

    static var chartGrid: Color {
        Color.primary.opacity(0.16)
    }
}

enum TunixBrand {
    static let accent = Color("BrandAccent")
    static let secondary = Color("BrandSecondary")
    static let healthy = Color.green
    static let warning = Color.orange
    static let critical = Color.red
}

struct TunixSignalMark: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: width * 0.11, y: height * 0.54))
                path.addLine(to: CGPoint(x: width * 0.30, y: height * 0.54))
                path.addLine(to: CGPoint(x: width * 0.37, y: height * 0.33))
                path.addLine(to: CGPoint(x: width * 0.46, y: height * 0.73))
                path.addLine(to: CGPoint(x: width * 0.54, y: height * 0.48))
                path.addLine(to: CGPoint(x: width * 0.61, y: height * 0.54))
                path.addLine(to: CGPoint(x: width * 0.86, y: height * 0.54))
            }
            .stroke(
                TunixBrand.accent,
                style: StrokeStyle(lineWidth: max(2, width * 0.0625), lineCap: .round, lineJoin: .round)
            )
            Circle()
                .fill(TunixBrand.secondary)
                .frame(width: max(3, width * 0.055), height: max(3, width * 0.055))
                .position(x: width * 0.86, y: height * 0.54)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

enum TunixLayoutClass: Equatable {
    case compact
    case standard
    case wide
    case large

    init(detailWidth: CGFloat, sidebarWidth: CGFloat = 210) {
        let windowWidth = detailWidth + sidebarWidth
        switch windowWidth {
        case ..<1100: self = .compact
        case ..<1400: self = .standard
        case ..<1700: self = .wide
        default: self = .large
        }
    }
}

struct TunixAdaptivePage<Content: View>: View {
    private let content: (TunixLayoutClass) -> Content

    init(@ViewBuilder content: @escaping (TunixLayoutClass) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = TunixLayoutClass(detailWidth: proxy.size.width)
            ScrollView {
                content(layout)
                    .padding(TunixDesign.pagePadding)
            }
        }
    }
}

struct TunixPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TunixSignalMark()
                .frame(width: 30, height: 30)
                .background(TunixBrand.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TunixSectionHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TunixPanel<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(TunixDesign.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TunixDesign.panelFill,
                in: RoundedRectangle(cornerRadius: TunixDesign.panelRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TunixDesign.panelRadius, style: .continuous)
                    .stroke(TunixDesign.panelStroke, lineWidth: 0.75)
            }
    }
}

struct TunixMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TunixChartFrame<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .frame(height: TunixDesign.chartHeight)
            .accessibilityHidden(true)
    }
}

struct TunixStatusBadge: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }
}

struct TunixValueBlock: View {
    let label: String
    let value: String
    var detail: String?
    var emphasis: Font = .title2

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(emphasis.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

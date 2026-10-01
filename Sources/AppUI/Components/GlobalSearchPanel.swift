import AIDomain
import SwiftUI

/// 跨页全局搜索面板（#414）。
///
/// ⚠️ 它是**浮层**：必须挂在窗口最外层（见 `MainView` 的挂载点）——
/// 挂在某一栏里就会被侧栏 / 森林盖住（划词浮卡那次的教训）。
public struct GlobalSearchPanel: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState
    /// 输入防抖：每敲一个字都去读一遍内置词库太浪费，停手 220ms 才真的搜。
    @State private var debounceTask: Task<Void, Never>?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            inputRow
            Divider().overlay(theme.divider)
            resultArea
        }
        .frame(width: 560, height: 420)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(theme.isNight ? 0.45 : 0.18), radius: 24, y: 10)
        .onDisappear { debounceTask?.cancel() }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .appFont(13)
                .foregroundStyle(theme.secondaryText)
            TextField("搜生词、词典、练过的对话、读过的短文", text: $state.globalSearchQuery)
                .textFieldStyle(.plain)
                .appFont(14, design: .rounded)
                .onSubmit { searchNow() }
                .onChange(of: state.globalSearchQuery) { _, _ in scheduleSearch() }
            if state.isSearchingGlobally {
                ProgressView().controlSize(.small)
            }
            Button {
                state.closeGlobalSearch()
            } label: {
                Image(systemName: "xmark")
                    .appFont(11, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.appPressable)
            .help("关闭搜索")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    @ViewBuilder
    private var resultArea: some View {
        if state.globalSearchHits.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .appFont(22)
                    .foregroundStyle(theme.secondaryText.opacity(0.5))
                Text(hintText)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(grouped, id: \.kind) { group in
                        sectionHeader(group.kind)
                        ForEach(group.items) { hit in
                            resultRow(hit)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .appPadding(.vertical, 8)
            }
        }
    }

    private var hintText: String {
        if GlobalSearch.normalize(state.globalSearchQuery).isEmpty {
            return "输入一个词，四个地方一起找：词汇本、词典、练过的对话、读过的短文。"
        }
        return state.isSearchingGlobally ? "正在找…" : "没有找到匹配的条目。"
    }

    /// 按来源分组（结果本身已排好序，这里只切段，不重排）。
    private var grouped: [(kind: GlobalSearchKind, items: [GlobalSearchHit])] {
        var order: [GlobalSearchKind] = []
        var buckets: [GlobalSearchKind: [GlobalSearchHit]] = [:]
        for hit in state.globalSearchHits {
            if buckets[hit.kind] == nil { order.append(hit.kind) }
            buckets[hit.kind, default: []].append(hit)
        }
        return order.map { (kind: $0, items: buckets[$0] ?? []) }
    }

    private func sectionHeader(_ kind: GlobalSearchKind) -> some View {
        Text(kind.title)
            .appFont(10, weight: .semibold, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .appPadding(.top, 8)
    }

    private func resultRow(_ hit: GlobalSearchHit) -> some View {
        Button {
            Task { await state.open(globalSearchHit: hit) }
        } label: {
            HStack(spacing: 8) {
                Text(hit.title)
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(hit.detail)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .appFont(9, weight: .bold)
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .appPadding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.hover.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        .help("去「\(hit.kind.title)」看这个")
    }

    // MARK: - 搜索调度

    /// 敲字停下来 220ms 再搜：内置词典几万条，每个字都搜一遍是浪费。
    private func scheduleSearch() {
        debounceTask?.cancel()
        let query = state.globalSearchQuery
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await state.performGlobalSearch(query)
        }
    }

    private func searchNow() {
        debounceTask?.cancel()
        Task { await state.performGlobalSearch(state.globalSearchQuery) }
    }
}

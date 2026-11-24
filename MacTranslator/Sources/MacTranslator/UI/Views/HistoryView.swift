import SwiftUI

struct HistoryView: View {
    @ObservedObject var vm: HistoryViewModel
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if vm.filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("暂无记录")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(vm.filteredRecords) { record in
                        historyRow(record)
                            .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        let visible = vm.filteredRecords
                        for index in offsets {
                            vm.delete(id: visible[index].id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 600, height: 500)
        .alert("清除所有历史与收藏？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { vm.clearAll() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $vm.tab) {
                ForEach(HistoryTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            TextField("🔎 搜索原文或译文…", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()
            Button("清空") { showClearConfirm = true }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: record.timestamp))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Badge(
                        text: record.sourceType.displayName,
                        tint: record.sourceType == .ocr ? .purple : .blue
                    )
                }
                Text(record.original)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(record.translated)
                    .font(.system(size: 13))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.interfaceName)
                        .font(.system(size: 10.5))
                        .foregroundColor(.green)
                    if let degraded = record.degradedFrom {
                        Text("由 \(degraded) 降级")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
            Spacer(minLength: 4)
            Button(action: { vm.toggleFavorite(id: record.id) }) {
                Image(systemName: record.isFavorite ? "star.fill" : "star")
                    .foregroundColor(record.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(record.isFavorite ? "取消收藏" : "收藏")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

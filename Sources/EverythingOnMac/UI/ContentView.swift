import Foundation
import EverythingOnMacCore

#if os(macOS)
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("输入查询，支持 path:/ ext:/ -排除 regex:true case:true", text: $viewModel.queryText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.queryText) { _, _ in viewModel.onQueryChanged() }

                Picker("模式", selection: $viewModel.mode) {
                    Text("混合").tag(SearchMode.mixed)
                    Text("仅文件名").tag(SearchMode.filenameOnly)
                    Text("仅正文").tag(SearchMode.contentOnly)
                }
                .onChange(of: viewModel.mode) { _, _ in viewModel.onQueryChanged() }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            HStack {
                Text("排序:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $viewModel.sortField) {
                    Text("相关性").tag(SortField.relevance)
                    Text("路径").tag(SortField.path)
                    Text("文件名").tag(SortField.filename)
                    Text("大小").tag(SortField.size)
                    Text("修改日期").tag(SortField.modificationDate)
                }
                .onChange(of: viewModel.sortField) { _, _ in viewModel.onQueryChanged() }
                .frame(width: 140)

                Picker("", selection: $viewModel.sortDirection) {
                    Text("升序").tag(SortDirection.ascending)
                    Text("降序").tag(SortDirection.descending)
                }
                .onChange(of: viewModel.sortDirection) { _, _ in viewModel.onQueryChanged() }
                .pickerStyle(.segmented)
                .frame(width: 120)

                Spacer()
            }

            HStack {
                Text(viewModel.isIndexing ? "索引构建中..." : "索引已就绪")
                Text("已索引: \(viewModel.indexedCount)")
                if let firstVolume = viewModel.volumeCapabilities.first {
                    Text(firstVolume.isAPFS ? "APFS/持久 File ID" : "标准文件系统索引")
                }
                Spacer()
                Text("结果: \(viewModel.results.count)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if viewModel.isTruncated {
                Text("仅显示当前排序下的最佳结果；请缩小查询范围或使用显式分页查看更多。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let lastError = viewModel.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            List(viewModel.results, id: \.metadata.path) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.metadata.filename)
                        .font(.headline)
                    Text(result.metadata.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let first = result.contentMatches.first {
                        Text("L\(first.line): \(first.text)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    viewModel.openResult(result)
                }
            }
        }
        .padding(16)
    }
}
#endif

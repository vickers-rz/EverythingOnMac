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
                Text(viewModel.isIndexing ? "索引构建中..." : "索引已就绪")
                Spacer()
                Text("结果: \(viewModel.results.count)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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

import AppKit
import SwiftUI
import Observation

@Observable
private final class OverviewModel {
    var context = ""
    var onSelect: ((AppSection) -> Void)?
}

@MainActor
final class HomeViewController: SectionViewController {
    var onSelect: ((AppSection) -> Void)?
    private let model = OverviewModel()
    override func build() {
        let host = NSHostingView(rootView: OverviewView(model: model))
        content.addSubview(host); host.pin(to: content)
        model.onSelect = { [weak self] in self?.onSelect?($0) }
    }
    override func reload(refresh: Bool) { model.context = "\(tab.label) · \(tab.region)" }
}

private struct OverviewView: View {
    let model: OverviewModel
    private let groups = AppSection.overviewGroups
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Explore your AWS account").font(.title3.weight(.semibold))
                        Text("Choose a service, or press ⌘K to jump anywhere.").foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button("New investigation") { model.onSelect?(.investigation) }
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.0) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group.0).font(.headline).padding(.bottom, 10)
                                ForEach(group.1, id: \.self) { service in
                                    Button { model.onSelect?(service) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: service.symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(service.title).foregroundStyle(.primary).font(.callout.weight(.medium))
                                                Text(service.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                        }.padding(.vertical, 10).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }.frame(height: 184)
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 8)
        }
    }
}

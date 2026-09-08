import SwiftUI

// Просмотр журналов: супервизор и openconnect, автопрокрутка, фильтр по
// подстроке, «показать в Finder». Ничего не меняет — только читает.
struct LogsView: View {
    @State private var sources: [LogSource] = []
    @State private var current: String = "supervisor"
    @State private var filter = ""
    @State private var snapshot = LogReader.Snapshot()
    @State private var follow = true
    @State private var timer: Timer?

    private var source: LogSource? {
        sources.first { $0.id == current } ?? sources.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 360)
        .onAppear { loadSources(); reload(); start() }
        .onDisappear { timer?.invalidate() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $current) {
                ForEach(sources) { s in Text(s.title).tag(s.id) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 400)
            .onChange(of: current) { _ in reload() }

            TextField("фильтр по подстроке", text: $filter)
                .textFieldStyle(.roundedBorder)
                .onChange(of: filter) { _ in reload() }
            if !filter.isEmpty {
                Button { filter = ""; reload() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(Palette.tertiary)
            }
            Toggle("следить", isOn: $follow).toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let problem = snapshot.problem {
                        Text(problem).font(.ocNote).foregroundStyle(Palette.tertiary)
                            .padding(12)
                    }
                    ForEach(snapshot.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: snapshot.lines.count) { _ in
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(source?.path ?? "—")
                .font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Text("\(snapshot.lines.count) строк · \(Size.bytes(Double(snapshot.size)))")
                .font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            Button("Показать в Finder") {
                guard let path = source?.path else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(source == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func color(_ kind: LogReader.Line.Kind) -> Color {
        switch kind {
        case .plain: return Palette.text
        case .good: return Palette.ok
        case .bad: return Palette.bad
        }
    }

    private func loadSources() {
        let v = OcbarClient.shared.versions()
        sources = [
            LogSource(id: "supervisor", title: "Супервизор",
                      path: v["supervisor_log"] ?? OcbarClient.shared.supervisorLog),
            LogSource(id: "openconnect", title: "openconnect",
                      path: v["openconnect_log"] ?? OcbarClient.shared.openconnectLog),
            LogSource(id: "proxy", title: "прокси",
                      path: v["proxy_log"] ?? OcbarClient.shared.proxyLog),
            LogSource(id: "app", title: "Приложение", path: AppLog.path),
        ]
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in reload() }
    }

    private func reload() {
        guard let source else { return }
        let filter = self.filter
        DispatchQueue.global(qos: .utility).async {
            let snap = LogReader.read(path: source.path, filter: filter)
            DispatchQueue.main.async { self.snapshot = snap }
        }
    }
}

import SwiftUI
import CoreMIDI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var copyTarget = 0
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HSplitView {
                devicePanel.frame(minWidth: 380)
                filePanel.frame(minWidth: 380)
            }
            Divider()
            logPanel.frame(height: 170)
        }
        .frame(minWidth: 900, minHeight: 620)
        // .syx / .ewi をウインドウのどこにドロップしても開ける
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { ["syx", "ewi"].contains($0.pathExtension.lowercased()) }
            guard let url = files.first ?? urls.first else { return false }
            model.openFile(url)
            if urls.count > 1 { model.append("複数のファイルがドロップされました。最初の \(url.lastPathComponent) を開きました") }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    Text("ここにドロップして開く（.syx / .ewi）").font(.title2.bold()).foregroundStyle(Color.accentColor)
                }
                .padding(6)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: 接続

    private var connectionBar: some View {
        HStack(spacing: 12) {
            Picker("入力", selection: $model.inputID) {
                Text("（なし）").tag(MIDIUniqueID?.none)
                ForEach(model.inputs) { Text($0.name).tag(MIDIUniqueID?.some($0.id)) }
            }.frame(width: 230)
            Picker("出力", selection: $model.outputID) {
                Text("（なし）").tag(MIDIUniqueID?.none)
                ForEach(model.outputs) { Text($0.name).tag(MIDIUniqueID?.some($0.id)) }
            }.frame(width: 230)
            Button(model.connected ? "再接続" : "接続") { model.connect() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.busy || model.inputID == nil || model.outputID == nil)
            Spacer()
            if model.busy {
                if let p = model.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                Text(model.progressText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else if let info = model.info, model.connected {
                Label("EWI5000  FW \(info.firmware)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("未接続", systemImage: "circle").foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    // MARK: 本体

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本体のユーザーバンク").font(.headline)
                Spacer()
                Button("読み直す") { model.reloadUserBank() }.disabled(!model.connected || model.busy)
            }
            List(selection: $model.deviceSelection) {
                ForEach(Array(model.userBank.enumerated()), id: \.offset) { i, p in
                    HStack {
                        Text(String(format: "%02d", i)).monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        Text(model.catalog.name(for: p))
                        Spacer()
                        if let f = model.file, !f.isSingle, i < f.patches.count, f.patches[i] != p {
                            Text("ファイルと違う").font(.caption).foregroundStyle(.orange)
                        }
                        Text(p.category).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(i)
                }
            }
            .overlay {
                if model.userBank.isEmpty {
                    Text("EWI5000 をつないで「接続」を押してください").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("一括バックアップ…") { model.backupAll() }
                Button("選んだ音色を保存…") { model.backupSelected() }.disabled(model.deviceSelection.isEmpty)
                Spacer()
                Button("本体設定をバックアップ…") { model.backupSettings() }.disabled(!model.connected)
                Menu("その他") {
                    Button("SDカード用 USERLIB.EWI を書き出す…") { model.exportUserLib() }
                    Button("自動バックアップのフォルダを開く") { model.openBackupFolder() }
                }.frame(width: 90)
            }
            .disabled(model.userBank.isEmpty || model.busy)
            HStack {
                Text("本体内コピー：")
                Text(model.deviceSelection.count == 1 ? String(format: "User %02d →", model.deviceSelection.first!) : "（コピー元を1つ選ぶ）")
                    .foregroundStyle(.secondary)
                Picker("", selection: $copyTarget) {
                    ForEach(0..<EWI.userSlots, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }.frame(width: 70)
                Button("コピー") {
                    if let s = model.deviceSelection.first { model.copyOnDevice(from: s, to: copyTarget) }
                }
                .disabled(model.deviceSelection.count != 1 || model.deviceSelection.first == copyTarget || !model.connected || model.busy)
            }
        }
        .padding(10)
    }

    // MARK: ファイル

    private var filePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ファイル").font(.headline)
                if let f = model.file { Text(f.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button("ファイルを開く…") { model.openFile() }.keyboardShortcut("o", modifiers: .command)
            }
            if let f = model.file {
                if f.isSingle {
                    singleFileView(f)
                } else {
                    bankFileView(f)
                }
            } else {
                Spacer()
                Text("バックアップした .syx か、SDカードの USERLIB.EWI / patchlib.ewi を、ここにドラッグ＆ドロップするか「ファイルを開く…」で開くと、本体に書き戻せます。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(10)
    }

    private func bankFileView(_ f: LoadedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(Array(f.patches.enumerated()), id: \.offset) { i, p in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { model.fileChecked.contains(i) },
                            set: { if $0 { model.fileChecked.insert(i) } else { model.fileChecked.remove(i) } }
                        )).labelsHidden()
                        Text(String(format: "%02d", i)).monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        Text(model.catalog.name(for: p))
                        Spacer()
                        if i < model.userBank.count, model.userBank[i] == p {
                            Text("本体と同じ").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button("違う番号を全部選ぶ") {
                    model.fileChecked = Set(f.patches.indices.filter { $0 < model.userBank.count && model.userBank[$0] != f.patches[$0] })
                }.disabled(model.userBank.isEmpty)
                Button("選択を外す") { model.fileChecked = [] }
                Spacer()
                Button("チェックした音色を書き込む（同じ番号へ）") { model.restore(all: false) }
                    .disabled(!model.connected || model.busy || model.fileChecked.isEmpty)
            }
        }
    }

    private func singleFileView(_ f: LoadedFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.catalog.name(for: f.patches[0])).font(.title3)
                    Text("サンプル：\(f.patches[0].category) \(f.patches[0].bytes[8])-\(f.patches[0].bytes[9])").foregroundStyle(.secondary)
                    if let o = f.origin {
                        Text("保存元：\(o.bank == EWI.userBank ? "User" : "Preset") \(String(format: "%02d", o.program))").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("書き込み先：User")
                Picker("", selection: $model.singleTarget) {
                    ForEach(0..<EWI.userSlots, id: \.self) { i in
                        Text(String(format: "%02d", i) + (i < model.userBank.count ? "  " + model.catalog.name(for: model.userBank[i]) : "")).tag(i)
                    }
                }.frame(width: 260)
                Spacer()
                Button("この番号に書き込む") { model.restore(all: false) }
                    .disabled(!model.connected || model.busy)
            }
            Spacer()
        }
    }

    // MARK: ログ

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ログ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("MIDIの送受信も表示", isOn: $model.showTraffic).toggleStyle(.checkbox).font(.caption)
                Button("消去") { model.log.removeAll() }.font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            Text(timeString(line.time) + "  " + line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.isError ? Color.red : Color.primary)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.log.count) { _ in
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

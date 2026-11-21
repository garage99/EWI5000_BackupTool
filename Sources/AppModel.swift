import Foundation
import AppKit
import SwiftUI
import CoreMIDI

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let isError: Bool
}

struct LoadedFile {
    let url: URL
    let patches: [Patch]
    let isSingle: Bool
    let origin: (bank: UInt8, program: UInt8)?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let midi = CoreMIDITransport()
    let engine: MIDIEngine
    let device: EWIDevice

    @Published var inputs: [MIDIPort] = []
    @Published var outputs: [MIDIPort] = []
    @Published var inputID: MIDIUniqueID?
    @Published var outputID: MIDIUniqueID?

    @Published var connected = false
    @Published var info: DeviceInfo?
    @Published var catalog = SampleCatalog()
    @Published var userBank: [Patch] = []
    @Published var presetBank: [Patch] = []
    @Published var deviceSelection = Set<Int>()

    @Published var file: LoadedFile?
    @Published var fileChecked = Set<Int>()
    @Published var singleTarget = 0

    @Published var busy = false
    @Published var progress: Double?
    @Published var progressText = ""
    @Published var log: [LogLine] = []
    @Published var showTraffic = false

    private init() {
        engine = MIDIEngine(transport: midi)
        device = EWIDevice(engine: engine)
        engine.onMessage = { [weak self] incoming, bytes in
            guard let self else { return }
            Task { @MainActor in
                guard self.showTraffic else { return }
                self.append((incoming ? "← " : "→ ") + hex(bytes), error: false)
            }
        }
        midi.onSetupChanged = { [weak self] in Task { @MainActor in self?.refreshPorts() } }
        refreshPorts()
    }

    // MARK: ログ

    func append(_ s: String, error: Bool = false) {
        log.append(LogLine(text: s, isError: error))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: ポート

    func refreshPorts() {
        inputs = midi.inputs()
        outputs = midi.outputs()
        if inputID == nil || !inputs.contains(where: { $0.id == inputID }) {
            inputID = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("EWI") })?.id
        }
        if outputID == nil || !outputs.contains(where: { $0.id == outputID }) {
            outputID = outputs.first(where: { $0.name.localizedCaseInsensitiveContains("EWI") })?.id
        }
        if connected && !midi.isConnected { connected = false }
    }

    // MARK: 共通の実行枠

    private func run(_ title: String, _ body: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        progress = nil
        progressText = title
        Task {
            do { try await body() } catch { self.append("\(title)：\(error.localizedDescription)", error: true) }
            self.busy = false
            self.progress = nil
            self.progressText = ""
        }
    }

    // MARK: 接続と読み出し

    func connect() {
        let i = inputs.first { $0.id == inputID }, o = outputs.first { $0.id == outputID }
        guard midi.select(input: i, output: o) else {
            append("MIDI ポートを開けませんでした。EWI5000 を USB でつないで電源を入れてください。", error: true)
            return
        }
        run("接続") {
            let info = try await self.device.identify()
            self.info = info
            self.append("EWI5000 を確認しました（ファームウェア \(info.firmware)、シリアル \(info.serial)）")
            try await self.device.ensureSynthMode()
            self.catalog = try await self.device.catalog()
            self.append("サンプル一覧：\(self.catalog.names.count) 種類")
            try await self.loadUserBank()
            self.connected = true
        }
    }

    func reloadUserBank() { run("ユーザーバンクの読み出し") { try await self.loadUserBank() } }

    private func loadUserBank() async throws {
        userBank = try await device.readBank(EWI.userBank)
        append("ユーザーバンク 00〜99 を読み出しました")
    }

    private func ensurePresetBank() async throws {
        if presetBank.isEmpty {
            presetBank = try await device.readBank(EWI.presetBank)
            append("プリセットバンクを読み出しました（復元に使うサンプルの確認用）")
        }
    }

    // MARK: バックアップ

    func backupAll() {
        guard !userBank.isEmpty else { return }
        guard let url = savePanel(name: "EWI5000_UserBank_\(stamp()).syx", types: ["syx"]) else { return }
        write(BackupFile.bankSysEx(userBank), to: url, what: "ユーザーバンク一括バックアップ")
    }

    func backupSelected() {
        let slots = deviceSelection.sorted()
        guard !slots.isEmpty, !userBank.isEmpty else { return }
        if slots.count == 1, let s = slots.first {
            let name = "EWI5000_User\(String(format: "%02d", s))_\(safe(catalog.name(for: userBank[s]))).syx"
            guard let url = savePanel(name: name, types: ["syx"]) else { return }
            write(BackupFile.singleSysEx(userBank[s], bank: EWI.userBank, program: UInt8(s)), to: url, what: "User \(String(format: "%02d", s))")
        } else {
            guard let dir = folderPanel() else { return }
            for s in slots {
                let url = dir.appendingPathComponent("EWI5000_User\(String(format: "%02d", s))_\(safe(catalog.name(for: userBank[s]))).syx")
                write(BackupFile.singleSysEx(userBank[s], bank: EWI.userBank, program: UInt8(s)), to: url, what: "User \(String(format: "%02d", s))")
            }
        }
    }

    /// 本体設定（Controlモードの約330項目）を .syx と .csv で保存
    func backupSettings() {
        guard connected else { return }
        guard let url = savePanel(name: "EWI5000_本体設定_\(stamp()).syx", types: ["syx"]) else { return }
        run("本体設定の読み出し") {
            let settings = try await self.device.readSettings()
            self.write(SettingsFile.sysEx(settings), to: url, what: "本体設定（\(settings.count) 項目）")
            let csvURL = url.deletingPathExtension().appendingPathExtension("csv")
            do {
                try SettingsFile.csv(settings).data(using: .utf8)!.write(to: csvURL)
                self.append("一覧を保存しました → \(csvURL.path)")
            } catch {
                self.append("一覧（CSV）を保存できませんでした：\(error.localizedDescription)", error: true)
            }
        }
    }

    func exportUserLib() {
        guard !userBank.isEmpty else { return }
        guard confirm("SDカード用の USERLIB.EWI を書き出します。",
                      detail: "本体の microSD カードの USERLIB.EWI と入れ替えると、ユーザーバンクを丸ごと戻せます。入れ替える前に、カードの元のファイルを必ず別の場所に保存してください。") else { return }
        guard let url = savePanel(name: "USERLIB.EWI", types: ["EWI", "ewi"]) else { return }
        write(BackupFile.userLib(userBank), to: url, what: "USERLIB.EWI")
    }

    private func write(_ bytes: [UInt8], to url: URL, what: String) {
        do {
            try Data(bytes).write(to: url)
            append("\(what) を保存しました → \(url.path)")
        } catch {
            append("\(what) を保存できませんでした：\(error.localizedDescription)", error: true)
        }
    }

    /// 書き込む前の自動バックアップ（Application Support と、開いたファイルと同じフォルダ）
    private func autoBackup() throws {
        let bytes = Data(BackupFile.bankSysEx(userBank))
        let name = "自動バックアップ_UserBank_\(stamp()).syx"
        let dir = Self.backupFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: dir.appendingPathComponent(name))
        if let f = file {
            try? bytes.write(to: f.url.deletingLastPathComponent().appendingPathComponent(name))
        }
        append("書き込む前のユーザーバンクを保存しました（\(name)）")
    }

    static var backupFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EWI5000 Bank Manager/バックアップ")
    }

    func openBackupFolder() {
        try? FileManager.default.createDirectory(at: Self.backupFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.backupFolder)
    }

    // MARK: ファイル

    func openFile() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["syx", "SYX", "ewi", "EWI"]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        openFile(url)
    }

    func openFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let f = BackupFile.load([UInt8](data)) else {
            if let data = try? Data(contentsOf: url), !SettingsFile.load([UInt8](data)).isEmpty {
                append("\(url.lastPathComponent) は本体設定のバックアップです（本体設定の書き戻しにはまだ対応していません）", error: true)
                return
            }
            append("\(url.lastPathComponent) は EWI5000 の音色ファイルとして読めませんでした", error: true)
            return
        }
        switch f {
        case .bank(let patches):
            file = LoadedFile(url: url, patches: patches, isSingle: false, origin: nil)
            fileChecked = []
            append("\(url.lastPathComponent) を開きました（一括・\(patches.count) 音色）")
        case .single(let p, let b, let n):
            file = LoadedFile(url: url, patches: [p], isSingle: true, origin: (b ?? EWI.userBank, n ?? 0))
            if let n, n < EWI.userSlots { singleTarget = Int(n) }
            append("\(url.lastPathComponent) を開きました（個別・\(catalog.name(for: p))）")
        }
    }

    // MARK: 書き込み

    /// 書き込む組み合わせ（ファイルの音色 → ユーザー番号）
    var plannedWrites: [(slot: Int, patch: Patch)] {
        guard let f = file else { return [] }
        if f.isSingle { return [(singleTarget, f.patches[0])] }
        return fileChecked.sorted().map { ($0, f.patches[$0]) }
    }

    func restore(all: Bool) {
        guard connected, let f = file, !userBank.isEmpty else { return }
        if all && !f.isSingle { fileChecked = Set(0..<f.patches.count) }
        let plan = plannedWrites.filter { userBank[$0.slot] != $0.patch }
        guard !plan.isEmpty else {
            append(plannedWrites.isEmpty ? "書き込む音色にチェックを入れてください" : "選んだ番号は、すでにファイルと同じ内容です")
            return
        }
        let list = plan.prefix(20).map { "User \(String(format: "%02d", $0.slot))：\(catalog.name(for: userBank[$0.slot])) → \(catalog.name(for: $0.patch))" }
            .joined(separator: "\n") + (plan.count > 20 ? "\n…ほか \(plan.count - 20) 件" : "")
        guard confirm("\(plan.count) 個の音色を本体に書き込みます。", detail: list + "\n\n書き込む前に、今のユーザーバンクを自動でバックアップします。音色を編集中の場合は、先に本体で保存か取り消しをしてください。通信中はEWI5000の操作やUSBの抜き差しをしないでください。") else { return }

        run("書き込み") {
            try self.autoBackup()
            try await self.ensurePresetBank()
            var failed = 0
            for (k, item) in plan.enumerated() {
                self.progress = Double(k) / Double(plan.count)
                self.progressText = "書き込み中 \(k + 1)/\(plan.count)：User \(String(format: "%02d", item.slot))"
                guard let donor = self.donor(for: item.patch, target: item.slot) else {
                    self.append("User \(String(format: "%02d", item.slot))：同じサンプル（\(self.catalog.name(for: item.patch))）を使う音色が本体にないため、書き込めません", error: true)
                    failed += 1
                    continue
                }
                do {
                    let sent = try await self.device.restore(item.patch, toSlot: item.slot, donor: donor)
                    self.append("User \(String(format: "%02d", item.slot)) に保存しました（パラメータ \(sent) 個を変更、読み戻して照合OK）")
                    self.userBank[item.slot] = item.patch
                } catch {
                    self.append("User \(String(format: "%02d", item.slot))：\(error.localizedDescription)", error: true)
                    failed += 1
                }
            }
            self.progress = 1
            self.progressText = "確認のため読み直しています"
            let expected = self.userBank
            try await self.loadUserBank()
            let bad = plan.filter { self.userBank[$0.slot] != $0.patch }.map { String(format: "%02d", $0.slot) }
            let planned = Set(plan.map { $0.slot })
            let mismatch = (0..<EWI.userSlots).filter { i in self.userBank[i] != expected[i] && !planned.contains(i) }
            if bad.isEmpty && mismatch.isEmpty && failed == 0 {
                self.append("書き込み完了：\(plan.count) 個すべて、本体から読み直して一致を確認しました")
            } else {
                if !bad.isEmpty { self.append("読み直したときに一致しなかった番号：\(bad.joined(separator: ", "))", error: true) }
                if !mismatch.isEmpty { self.append("書き込んでいないのに変わった番号：\(mismatch.map { String(format: "%02d", $0) }.joined(separator: ", "))", error: true) }
                if failed > 0 { self.append("\(failed) 個は書き込めませんでした", error: true) }
            }
        }
    }

    /// 同じサンプルを使う音色を探す（書き込み先そのもの → プリセット → ユーザー の順）
    func donor(for p: Patch, target: Int) -> (bank: UInt8, program: UInt8)? {
        let key = p.sampleKey
        if userBank[target].sampleKey == key { return (EWI.userBank, UInt8(target)) }
        if let i = presetBank.firstIndex(where: { $0.sampleKey == key }) { return (EWI.presetBank, UInt8(i)) }
        if let i = userBank.firstIndex(where: { $0.sampleKey == key }) { return (EWI.userBank, UInt8(i)) }
        return nil
    }

    // MARK: 本体内コピー

    func copyOnDevice(from src: Int, to dst: Int) {
        guard connected, src != dst, !userBank.isEmpty else { return }
        guard confirm("User \(String(format: "%02d", src))（\(catalog.name(for: userBank[src]))）を User \(String(format: "%02d", dst)) にコピーします。",
                      detail: "User \(String(format: "%02d", dst))（\(catalog.name(for: userBank[dst]))）は上書きされます。先に今のユーザーバンクを自動でバックアップします。") else { return }
        run("本体内コピー") {
            try self.autoBackup()
            let source = self.userBank[src]
            try await self.device.copy(from: src, to: dst)
            try await self.loadUserBank()
            if self.userBank[dst] == source {
                self.append("User \(String(format: "%02d", src)) → \(String(format: "%02d", dst)) のコピーを確認しました")
            } else {
                self.append("コピー後の User \(String(format: "%02d", dst)) が元と一致しません", error: true)
            }
        }
    }

    // MARK: 小物

    func confirm(_ message: String, detail: String = "") -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func savePanel(name: String, types: [String]) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedFileTypes = types
        p.allowsOtherFileTypes = true
        return p.runModal() == .OK ? p.url : nil
    }

    private func folderPanel() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "このフォルダに保存"
        return p.runModal() == .OK ? p.url : nil
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
    }
}

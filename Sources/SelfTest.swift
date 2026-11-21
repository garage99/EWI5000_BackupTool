// ビルド時の自己テスト:  EWI5000BankManager --selftest <tests フォルダ>
//  1. 実機から記録したダンプと SD カードのファイルを読み、形式の解釈を確かめる
//  2. 実機の動きをまねた「模擬 EWI5000」を相手に、読み出し・復元・コピーを通しで試す

import Foundation

/// 実機の通信記録どおりに応答する模擬 EWI5000
final class MockEWI: MIDITransport {
    var onReceive: (([UInt8]) -> Void)?
    var preset: [Patch]
    var user: [Patch]
    var bank: UInt8 = 1, program: UInt8 = 0
    var edit: Patch
    var mode: UInt8 = 0
    let catalogText: [UInt8]
    private let parser = MIDIStreamParser()
    private var pendingBank: UInt8 = 1
    private var nrpnMSB = 0, nrpnLSB = 0
    private let q = DispatchQueue(label: "mock.ewi")
    var stores: [(UInt8, UInt8)] = []
    var settings: [[UInt8]] = []
    var nrpnCount = 0

    init(preset: [Patch], user: [Patch], catalog: [UInt8]) {
        self.preset = preset; self.user = user; self.catalogText = catalog
        edit = user[0]
    }

    func send(_ bytes: [UInt8]) {
        q.async {
            var msgs: [[UInt8]] = []
            self.parser.feed(bytes) { msgs.append($0) }
            for m in msgs { self.handle(m) }
        }
    }

    private func reply(_ b: [UInt8]) {
        // 実機と同じように細切れで届ける
        q.asyncAfter(deadline: .now() + 0.005) {
            var i = 0
            while i < b.count { self.onReceive?(Array(b[i..<min(i + 256, b.count)])); i += 256 }
        }
    }

    private func handle(_ m: [UInt8]) {
        if m == EWI.identityRequest {
            reply([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x47, 0x20, 0x00, 0x19, 0x01, 0x05, 0x04, 0x06, 0x00, 0, 0, 0, 0] + Array("TEST0000000001".utf8) + [0x00, 0xF7])
        } else if m == EWI.getMode {
            reply(EWI.header + [0x00, 0x00, 0x05, mode, 0xF7])
        } else if m.count == 9, Array(m.prefix(7)) == EWI.header + [0x00, 0x00, 0x06] {
            mode = m[7]; reply(EWI.header + [0x00, 0x00, 0x05, mode, 0xF7])
        } else if m == EWI.settingsRequest[1] {
            if mode == 0 { for (k, x) in settings.enumerated() { q.asyncAfter(deadline: .now() + 0.002 * Double(k)) { self.onReceive?(x) } } }
        } else if m == EWI.requestCatalog {
            reply(EWI.header + [0x02, 0x00, 0x04] + catalogText + [0xF7])
        } else if m == EWI.requestBank {
            if bank == EWI.userBank {
                // ユーザーバンクは実機と同じく、124 番目の途中から壊れて（8 ビットのゴミが混ざって）届く
                var all = user.flatMap { $0.bytes }
                for _ in user.count..<123 { all += Patch.emptySlot.bytes }
                all += Array(Patch.emptySlot.bytes.prefix(150))
                reply(EWI.header + [0x02, 0x00, 0x06] + all + [0xFF, 0xFF, 0x00, 0x3F, 0x54, 0x00, 0xF7])
            } else {
                reply(EWI.header + [0x02, 0x00, 0x06] + preset.flatMap { $0.bytes } + [0xF7])
            }
        } else if m == EWI.requestEditBuffer {
            reply(EWI.header + [0x02, 0x00, 0x08] + edit.bytes + [bank, program, 0xF7])
        } else if m.count == 10, Array(m.prefix(7)) == EWI.header + [0x02, 0x00, 0x0A] {
            stores.append((m[7], m[8]))
            if m[7] == EWI.userBank, Int(m[8]) < user.count { user[Int(m[8])] = edit }
        } else if m.count == 3, m[0] == 0xB0 {
            switch m[1] {
            case 0x20: pendingBank = m[2]
            case 0x63: nrpnMSB = Int(m[2])
            case 0x62: nrpnLSB = Int(m[2])
            case 0x06: edit.bytes[10 + 2 * (nrpnMSB * 128 + nrpnLSB)] = m[2]; nrpnCount += 1
            case 0x26: edit.bytes[11 + 2 * (nrpnMSB * 128 + nrpnLSB)] = m[2]
            default: break
            }
        } else if m.count == 2, m[0] == 0xC0 {
            bank = pendingBank; program = m[1]
            let src = bank == EWI.userBank ? user : preset
            if Int(program) < src.count { edit = src[Int(program)] }
        }
    }
}

final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func check(_ cond: Bool, _ s: String) {
        lock.lock(); _lines.append((cond ? "OK   " : "FAIL ") + s); lock.unlock()
    }
}

enum SelfTest {
    static func run(_ dir: String) -> Int32 {
        let r = Reporter()
        let check = r.check

        let inDir = URL(fileURLWithPath: dir).appendingPathComponent("in")
        func bytes(_ name: String) -> [UInt8] { (try? [UInt8](Data(contentsOf: inDir.appendingPathComponent(name)))) ?? [] }

        var userLib = bytes("USERLIB.EWI"), patchLib = bytes("patchlib.ewi"), map = bytes("dlssnds.map")
        let realUserDump = bytes("userbank_dump_real.syx"), realEdit = bytes("editbuffer_real.syx")
        var settingsBytes = bytes("settings_reply_sample.syx")
        let hasReal = userLib.count == EWI.libFileSize && patchLib.count == EWI.libFileSize && !map.isEmpty
        if !hasReal {
            // SDカードのファイルがない環境（公開リポジトリ）では、同じ形の作り物のデータで試す
            let cats = ["sax", "airsax", "synths", "other"]
            map = Array(cats.flatMap { c in (0..<10).map { "\(c)\t1\t\($0)\tTest \(c) \($0)\n" } }.joined().utf8)
            var seed: UInt32 = 12345
            func rnd() -> UInt8 { seed = seed &* 1103515245 &+ 12345; return UInt8((seed >> 16) & 0x7F) }
            var pl: [UInt8] = []
            for i in 0..<EWI.libSlots {
                var r = [UInt8](repeating: 0, count: EWI.recordSize)
                for (k, ch) in cats[i % 4].utf8.enumerated() { r[k] = ch }
                r[8] = 1; r[9] = UInt8(i % 10)
                for k in 10..<140 { r[k] = rnd() }
                pl += r
            }
            patchLib = pl
            userLib = Array(pl.prefix(EWI.recordSize * EWI.userSlots)) + (EWI.userSlots..<EWI.libSlots).flatMap { _ in Patch.emptySlot.bytes }
            settingsBytes = ["ui.channel", "ui.auto_off", "breath.offset", "bite.noise_gate"].enumerated().flatMap { k, n -> [UInt8] in
                let v: [UInt8] = [UInt8(k), 0, 0, 0, 0], mx: [UInt8] = [0x0F, 0, 0, 0, 0], neg: [UInt8] = [0x78, 0x7F, 0x7F, 0x7F, 0x7F]
                return [0xF0, 0x47, 0x00, 0x20, 0x01, 0x41, 0x04] + v + neg + mx + v + Array(n.utf8) + [0x00, 0xF7]
            }
        }
        r.check(true, hasReal ? "SDカードのファイルと実機の記録で試験" : "作り物のデータで試験（SDカードのファイルなし）")
        let settingsSample = SettingsFile.load(settingsBytes)
        check(!settingsSample.isEmpty && settingsSample[0].name == "ui.channel" && settingsSample[0].max == 15, "本体設定の解釈（\(settingsSample.count) 項目）")
        if !hasReal { check(settingsSample[0].min == -8, "本体設定の負の値") }
        check(SettingsFile.load(SettingsFile.sysEx(settingsSample)).map { $0.name } == settingsSample.map { $0.name }, "本体設定 .syx の往復")
        let catalog = SampleCatalog(text: String(decoding: map, as: UTF8.self))
        check(catalog.names.count >= 40, "サンプル一覧 \(catalog.names.count) 種類")

        guard case .bank(let lib)? = BackupFile.load(userLib) else {
            check(false, "USERLIB.EWI を読めない"); return finish(r.lines, dir)
        }
        check(lib.count == 100, "USERLIB.EWI から 100 音色")
        if hasReal {
            check(catalog.name(for: lib[10]) == "Harmonica", "User 10 の名前 = \(catalog.name(for: lib[10]))")
            // 実機から届いたユーザーバンク（後半が壊れたもの）
            var msgs: [[UInt8]] = []
            MIDIStreamParser().feed(realUserDump) { msgs.append($0) }
            let dump = msgs.first { EWI.isReply($0, cmd: 0x06) }
            let parsed = dump.flatMap { parseBank(reply: $0, count: EWI.userSlots) }
            check(parsed != nil && parsed! == lib, "実機のユーザーバンクのダンプ（\(realUserDump.count)B）= USERLIB.EWI の 00〜99")
            var em: [[UInt8]] = []
            MIDIStreamParser().feed(realEdit) { em.append($0) }
            let eb = em.first.flatMap { EditBuffer(reply: $0) }
            check(eb != nil && eb!.bank == 1 && eb!.program == 0x63, "実機の「今の音色」= User 99")
        }

        // ファイルの往復
        let syx = BackupFile.bankSysEx(lib)
        if case .bank(let back)? = BackupFile.load(syx) { check(back == lib, "一括 .syx の書き出し→読み込み") } else { check(false, "一括 .syx を読めない") }
        check(BackupFile.userLib(lib) == userLib, "USERLIB.EWI の書き出しが元ファイルと同じ")
        if case .single(let p, let b, let n)? = BackupFile.load(BackupFile.singleSysEx(lib[7], bank: 1, program: 7)) {
            check(p == lib[7] && b == 1 && n == 7, "個別 .syx の往復")
        } else { check(false, "個別 .syx を読めない") }

        // 模擬本体で通し
        let preset: [Patch] = (0..<EWI.libSlots).map { Patch(Array(patchLib[($0 * 266)..<(($0 + 1) * 266)]))! }
        let mock = MockEWI(preset: preset, user: lib, catalog: map)
        mock.settings = settingsSample.map { $0.raw }
        let engine = MIDIEngine(transport: mock)
        let device = EWIDevice(engine: engine)
        device.selectDelay = 0.03; device.storeDelay = 0.02; device.nrpnInterval = 0

        // 書き込む音色：プリセット 40 番（User 5 とは別のサンプル）を元に、パラメータをいくつか変えたもの
        var target = preset[hasReal ? 40 : 2]
        for n in [0, 7, 52, 100] { target.bytes[10 + 2 * n] = UInt8((n + 3) & 0x7F); target.bytes[11 + 2 * n] = 0x55 }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let info = try await device.identify()
                check(info.firmware == "5.4.6.0" && info.serial == "TEST0000000001", "識別 \(info.firmware) \(info.serial)")
                try await device.ensureSynthMode()
                check(mock.mode == 1, "Synthモードに切り替え")
                let cat = try await device.catalog()
                check(cat.names.count == catalog.names.count, "サンプル一覧の受信")
                let u = try await device.readBank(EWI.userBank)
                check(u == lib, "ユーザーバンクの読み出し")
                mock.bank = 0; mock.program = 3
                let p = try await device.readBank(EWI.presetBank)
                check(p == preset, "プリセットバンクの読み出し（128）")
                let u2 = try await device.readBank(EWI.userBank)
                check(u2 == lib && mock.bank == 0 && mock.program == 3, "読み出し後に元の音色へ戻す")

                let donor = p.firstIndex { $0.sampleKey == target.sampleKey }!
                check(lib[5].sampleKey != target.sampleKey, "書き込み先と違うサンプルの音色で試す")
                let sent = try await device.restore(target, toSlot: 5, donor: (EWI.presetBank, UInt8(donor)))
                check(mock.user[5] == target, "復元：User 05 がファイルと一致（NRPN \(sent) 個）")
                check(mock.user.enumerated().allSatisfy { $0.offset == 5 || $0.element == lib[$0.offset] }, "復元：ほかの番号は変わらない")
                check(mock.preset == preset, "復元：プリセットは変わらない")

                let st = try await device.readSettings(idle: 0.2)
                check(st.count == settingsSample.count && mock.mode == 1, "本体設定の読み出し（\(st.count) 項目、Synthモードに戻る）")

                try await device.copy(from: 5, to: 6)
                check(mock.user[6] == target && mock.user[5] == target, "本体内コピー User 05 → 06")

                // 照合に失敗するときは保存しない
                let before = mock.user[8]
                var bad = lib[8]; bad.bytes[3] = 0x7A   // サンプル名が違う → 呼び出し時点で止まる
                do { try await device.restore(bad, toSlot: 8, donor: (EWI.userBank, 8)); check(false, "不一致なのに保存した") }
                catch { check(mock.user[8] == before, "不一致のときは保存しない") }
            } catch {
                check(false, "模擬本体：\(error.localizedDescription)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut { check(false, "模擬本体のテストが時間切れ") }
        let failed = r.lines.contains { $0.hasPrefix("FAIL") }
        return finish(r.lines + [failed ? "FAILED" : "ALL OK"], dir)
    }

    @discardableResult
    private static func finish(_ report: [String], _ dir: String) -> Int32 {
        let outDir = URL(fileURLWithPath: dir).deletingLastPathComponent().appendingPathComponent("build/selftest")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let text = report.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: outDir.appendingPathComponent("report.txt"))
        print(text, terminator: "")
        return report.contains { $0.hasPrefix("FAIL") } ? 1 : 0
    }
}

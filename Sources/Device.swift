// EWI5000 への操作（読み出し・復元・本体内コピー）

import Foundation

struct DeviceInfo {
    var firmware: String
    var serial: String
}

final class EWIDevice {
    let engine: MIDIEngine
    /// NRPN を 1 個送るごとの待ち時間（公式エディタは 10ms 前後の間隔で送っている）
    var nrpnInterval: Double = 0.006
    /// 音色選択から「今の音色」を読むまでの待ち時間（実機は 0.25 秒ほどで切り替わる）
    var selectDelay: Double = 0.35
    var storeDelay: Double = 0.5

    init(engine: MIDIEngine) { self.engine = engine }

    func identify() async throws -> DeviceInfo {
        let m = try await engine.request(EWI.identityRequest, what: "識別要求", match: EWI.isIdentityReply)
        // F0 7E dev 06 02 47 20 00 19 01 fw0 fw1 fw2 fw3 ... serial(ASCII) 00 F7
        let fw = m.count > 13 ? m[10...13].map { String($0) }.joined(separator: ".") : "?"
        let serialBytes = m.dropFirst(14).filter { $0 >= 0x20 && $0 < 0x7F }
        return DeviceInfo(firmware: fw, serial: String(decoding: serialBytes, as: UTF8.self))
    }

    func ensureSynthMode() async throws {
        let m = try await engine.request(EWI.getMode, what: "モード問い合わせ", match: EWI.isModeReply)
        if m[7] == 0x01 { return }
        _ = try await engine.request(EWI.setMode(synth: true), what: "Synthモードへの切り替え", timeout: 6) {
            EWI.isModeReply($0) && $0[7] == 0x01
        }
        await pause(0.3)
    }

    func catalog() async throws -> SampleCatalog {
        let m = try await engine.request(EWI.requestCatalog, what: "サンプル一覧") { EWI.isReply($0, cmd: 0x04) }
        return SampleCatalog(text: String(decoding: EWI.payload(m), as: UTF8.self))
    }

    func editBuffer() async throws -> EditBuffer {
        let m = try await engine.request(EWI.requestEditBuffer, what: "今の音色") { EWI.isReply($0, cmd: 0x08) }
        guard let eb = EditBuffer(reply: m) else { throw EWIError.badReply("今の音色 \(m.count)B") }
        return eb
    }

    @discardableResult
    func select(bank: UInt8, program: UInt8) async throws -> EditBuffer {
        for attempt in 0..<3 {
            engine.send(EWI.selectProgram(bank: bank, program: program))
            await pause(selectDelay + Double(attempt) * 0.4)
            let eb = try await editBuffer()
            if eb.bank == bank && eb.program == program { return eb }
        }
        throw EWIError.failed("\(bankName(bank)) \(String(format: "%02d", program)) に切り替わりませんでした")
    }

    /// 指定バンクを読む（必要ならバンクを切り替え、終わったら元の音色に戻す）
    func readBank(_ bank: UInt8) async throws -> [Patch] {
        let before = try await editBuffer()
        let switched = before.bank != bank
        func restoreSelection() async {
            guard switched else { return }
            engine.send(EWI.selectProgram(bank: before.bank, program: before.program))
            await pause(selectDelay)
        }
        do {
            if switched { try await select(bank: bank, program: 0) }
            let m = try await engine.request(EWI.requestBank, what: "\(bankName(bank))の読み出し", timeout: 10) { EWI.isReply($0, cmd: 0x06) }
            let count = bank == EWI.userBank ? EWI.userSlots : EWI.libSlots
            guard let patches = parseBank(reply: m, count: count) else {
                throw EWIError.badReply("\(bankName(bank)) \(m.count)B")
            }
            await restoreSelection()
            return patches
        } catch {
            await restoreSelection()
            throw error
        }
    }

    /// ファイルの音色 patch を、ユーザーバンクの slot 番に書き込む
    ///  1. 同じサンプルを使う音色（donor）を呼び出す
    ///  2. 違うパラメータだけ NRPN で送る
    ///  3. 今の音色を読み戻して 266 バイトすべて一致したときだけ保存
    @discardableResult
    func restore(_ patch: Patch, toSlot slot: Int, donor: (bank: UInt8, program: UInt8)) async throws -> Int {
        let current = try await select(bank: donor.bank, program: donor.program)
        guard current.patch.sampleKey == patch.sampleKey else {
            throw EWIError.failed("呼び出した音色のサンプルが一致しません（\(current.patch.category)）")
        }
        var sent = 0
        for n in 0..<EWI.paramCount {
            let want = patch.param(n), have = current.patch.param(n)
            if want != have {
                engine.send(EWI.nrpn(n, msb: want.msb, lsb: want.lsb))
                sent += 1
                await pause(nrpnInterval)
            }
        }
        await pause(0.15)
        let check = try await editBuffer()
        let diffs = check.patch.differences(from: patch)
        if !diffs.isEmpty {
            // 保存せずに書き込み先の音色を呼び直して、編集を捨てる
            engine.send(EWI.selectProgram(bank: EWI.userBank, program: UInt8(slot)))
            let where_ = diffs.prefix(8).map(String.init).joined(separator: ",")
            throw EWIError.failed("読み戻した音色がファイルと一致しません（\(diffs.count)か所: \(where_)）。保存していません。")
        }
        engine.send(EWI.store(bank: EWI.userBank, program: UInt8(slot)))
        await pause(storeDelay)
        return sent
    }

    /// 本体の中でユーザー src 番をユーザー dst 番にコピー
    func copy(from src: Int, to dst: Int) async throws {
        try await select(bank: EWI.userBank, program: UInt8(src))
        engine.send(EWI.store(bank: EWI.userBank, program: UInt8(dst)))
        await pause(storeDelay)
    }

    /// 本体設定を読む：Controlモードにして一覧を要求し、届かなくなるまで集める。終わったら Synth モードに戻す
    func readSettings(idle: Double = 0.8, maxWait: Double = 15) async throws -> [DeviceSetting] {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var items: [String: DeviceSetting] = [:]; var order: [String] = []; var last = Date()
        }
        let box = Box()
        let id = engine.addListener { m in
            guard let s = DeviceSetting(reply: m) else { return }
            box.lock.lock()
            if box.items[s.name] == nil { box.order.append(s.name) }
            box.items[s.name] = s
            box.last = Date()
            box.lock.unlock()
        }
        defer { engine.removeListener(id) }
        func backToSynth() async {
            _ = try? await engine.request(EWI.setMode(synth: true), what: "Synthモードに戻す", timeout: 6) { EWI.isModeReply($0) && $0[7] == 0x01 }
            await pause(0.3)
        }
        do {
            _ = try await engine.request(EWI.setMode(synth: false), what: "Controlモードへの切り替え", timeout: 6) { EWI.isModeReply($0) && $0[7] == 0x00 }
            box.lock.lock(); box.last = Date(); box.lock.unlock()
            for m in EWI.settingsRequest { engine.send(m) }
            let start = Date()
            while true {
                await pause(0.1)
                box.lock.lock(); let count = box.items.count; let quiet = Date().timeIntervalSince(box.last); box.lock.unlock()
                if count > 0 && quiet >= idle { break }
                if Date().timeIntervalSince(start) > maxWait {
                    if count == 0 { throw EWIError.timeout("本体設定の読み出し") }
                    break
                }
            }
        } catch {
            await backToSynth()
            throw error
        }
        await backToSynth()
        box.lock.lock(); defer { box.lock.unlock() }
        return box.order.compactMap { box.items[$0] }
    }

    func bankName(_ b: UInt8) -> String { b == EWI.userBank ? "User" : "Preset" }
}

// CoreMIDI の入出力と、「送って応答を待つ」仕組み

import Foundation
import CoreMIDI

struct MIDIPort: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
}

/// 実機（CoreMIDI）と自己テスト用の模擬本体の共通口
protocol MIDITransport: AnyObject {
    func send(_ bytes: [UInt8])
    var onReceive: (([UInt8]) -> Void)? { get set }
}

final class CoreMIDITransport: MIDITransport {
    private var client = MIDIClientRef()
    private var outPort = MIDIPortRef()
    private var inPort = MIDIPortRef()
    private var outEndpoint: MIDIEndpointRef = 0
    private var inEndpoint: MIDIEndpointRef = 0
    private let lock = NSLock()

    var onReceive: (([UInt8]) -> Void)?
    var onSetupChanged: (() -> Void)?
    private(set) var ready = false

    init() {
        let status = MIDIClientCreateWithBlock("EWI5000 Bank Manager" as CFString, &client) { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onSetupChanged?() }
            }
        }
        guard status == noErr else { return }
        MIDIOutputPortCreate(client, "EWI5000 Bank Manager Out" as CFString, &outPort)
        MIDIInputPortCreateWithBlock(client, "EWI5000 Bank Manager In" as CFString, &inPort) { [weak self] list, _ in
            self?.handleInput(list)
        }
        ready = true
    }

    private static func name(of e: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        if MIDIObjectGetStringProperty(e, kMIDIPropertyName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        return "Unknown"
    }

    private static func uniqueID(of e: MIDIEndpointRef) -> MIDIUniqueID {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &id)
        return id
    }

    func outputs() -> [MIDIPort] {
        (0..<MIDIGetNumberOfDestinations()).map { let e = MIDIGetDestination($0); return MIDIPort(id: Self.uniqueID(of: e), name: Self.name(of: e)) }
    }

    func inputs() -> [MIDIPort] {
        (0..<MIDIGetNumberOfSources()).map { let e = MIDIGetSource($0); return MIDIPort(id: Self.uniqueID(of: e), name: Self.name(of: e)) }
    }

    private func find(_ id: MIDIUniqueID) -> MIDIEndpointRef? {
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(id, &obj, &type) == noErr else { return nil }
        return obj
    }

    @discardableResult
    func select(input: MIDIPort?, output: MIDIPort?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inEndpoint != 0 { MIDIPortDisconnectSource(inPort, inEndpoint) }
        inEndpoint = 0; outEndpoint = 0
        var ok = true
        if let i = input, let e = find(i.id), MIDIPortConnectSource(inPort, e, nil) == noErr { inEndpoint = e } else { ok = false }
        if let o = output, let e = find(o.id) { outEndpoint = e } else { ok = false }
        return ok
    }

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return inEndpoint != 0 && outEndpoint != 0 }

    func send(_ bytes: [UInt8]) {
        lock.lock(); let dest = outEndpoint; lock.unlock()
        guard dest != 0, !bytes.isEmpty else { return }
        let size = bytes.count + 256
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        bytes.withUnsafeBufferPointer { p in
            packet = MIDIPacketListAdd(list, size, packet, 0, bytes.count, p.baseAddress!)
        }
        MIDISend(outPort, dest, list)
    }

    private func handleInput(_ list: UnsafePointer<MIDIPacketList>) {
        let offset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.length)
            guard count > 0 else { continue }
            let start = (UnsafeRawPointer(packet) + offset).assumingMemoryBound(to: UInt8.self)
            onReceive?(Array(UnsafeBufferPointer(start: start, count: count)))
        }
    }
}

enum EWIError: LocalizedError {
    case timeout(String)
    case badReply(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let s): return "応答がありません（\(s)）。EWI5000 の電源・USB接続と、公式エディタが閉じているかを確認してください。"
        case .badReply(let s): return "想定外の応答でした（\(s)）"
        case .failed(let s): return s
        }
    }
}

/// 受信を 1 メッセージずつに区切り、待っている要求に渡す
final class MIDIEngine {
    let transport: MIDITransport
    private let parser = MIDIStreamParser()
    private let lock = NSLock()
    private var waiters: [UUID: (match: ([UInt8]) -> Bool, cont: CheckedContinuation<[UInt8], Error>)] = [:]
    private var listeners: [UUID: ([UInt8]) -> Void] = [:]
    var onMessage: ((_ incoming: Bool, _ bytes: [UInt8]) -> Void)?

    init(transport: MIDITransport) {
        self.transport = transport
        transport.onReceive = { [weak self] bytes in self?.receive(bytes) }
    }

    private func receive(_ bytes: [UInt8]) {
        lock.lock()
        var msgs: [[UInt8]] = []
        parser.feed(bytes) { msgs.append($0) }
        lock.unlock()
        for m in msgs {
            onMessage?(true, m)
            lock.lock()
            let ls = Array(listeners.values)
            let hit = waiters.first { $0.value.match(m) }
            if let hit { waiters.removeValue(forKey: hit.key) }
            lock.unlock()
            for l in ls { l(m) }
            hit?.value.cont.resume(returning: m)
        }
    }

    /// 届いたメッセージをすべて受け取る（返り値で解除）
    func addListener(_ f: @escaping ([UInt8]) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = f; lock.unlock()
        return id
    }

    func removeListener(_ id: UUID) {
        lock.lock(); listeners.removeValue(forKey: id); lock.unlock()
    }

    func send(_ bytes: [UInt8]) {
        onMessage?(false, bytes)
        transport.send(bytes)
    }

    /// 送信して、match に合う応答が来るまで待つ
    func request(_ bytes: [UInt8], what: String, timeout: TimeInterval = 4, match: @escaping ([UInt8]) -> Bool) async throws -> [UInt8] {
        let id = UUID()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            lock.lock(); waiters[id] = (match, cont); lock.unlock()
            send(bytes)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let w = self.waiters.removeValue(forKey: id)
                self.lock.unlock()
                w?.cont.resume(throwing: EWIError.timeout(what))
            }
        }
    }
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

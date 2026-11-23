import Foundation
import MLX

// Protocol on stdin: one JSON line, then `samples` little-endian Int16 values when kind is a job.
//   {"id":1,"kind":"partial"|"final","samples":N,"language":"Chinese","context":"..."}
//   {"id":1,"kind":"cancel"}
// Replies on stdout, one JSON line each. The process exits when stdin closes, so it cannot
// outlive its owner even after SIGKILL. It opens no sockets.

struct Request: Decodable {
    let id: Int
    let kind: String
    var samples: Int?
    var language: String?
    var context: String?
}

struct Job {
    let request: Request
    let pcm: [Float]
}

final class Queue {
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var runningID: Int?
    private var runningIsPartial = false
    private var cancelled = Set<Int>()

    func push(_ job: Job) {
        condition.lock()
        if job.request.kind == "final" {
            // A final outranks every partial: drop queued ones and stop the one in flight.
            for queued in jobs where queued.request.kind == "partial" {
                cancelled.insert(queued.request.id)
            }
            if runningIsPartial, let runningID { cancelled.insert(runningID) }
            let firstPartial = jobs.firstIndex { $0.request.kind == "partial" } ?? jobs.endIndex
            jobs.insert(job, at: firstPartial)
        } else {
            jobs.append(job)
        }
        condition.signal()
        condition.unlock()
    }

    func cancel(_ id: Int) {
        condition.lock()
        cancelled.insert(id)
        condition.unlock()
    }

    func pop() -> Job {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty { condition.wait() }
        let job = jobs.removeFirst()
        runningID = job.request.id
        runningIsPartial = job.request.kind == "partial"
        return job
    }

    func isCancelled(_ id: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled.contains(id)
    }

    func finish(_ id: Int) {
        condition.lock()
        runningID = nil
        runningIsPartial = false
        cancelled.remove(id)
        condition.unlock()
    }
}

func reply(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

/// Current and peak physical footprint, the figure Activity Monitor reports as Memory.
func footprintMB() -> (current: Int, peak: Int) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { return (0, 0) }
    return (Int(info.phys_footprint >> 20), Int(info.ledger_phys_footprint_peak >> 20))
}

func readExact(_ count: Int) -> [Int16]? {
    var buffer = [Int16](repeating: 0, count: count)
    let got = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, stdin) }
    return got == count * 2 ? buffer : nil
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: juxu-qwen-asr MODEL_DIR\n".utf8))
    exit(2)
}

let queue = Queue()
let reader = Thread {
    let decoder = JSONDecoder()
    while let line = readLine(strippingNewline: true) {
        guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else {
            reply(["event": "error", "message": "bad request"])
            continue
        }
        if request.kind == "cancel" {
            queue.cancel(request.id)
            continue
        }
        guard let samples = request.samples, samples >= 0, samples <= 16_000 * 1_200,
              let pcm = readExact(samples) else {
            reply(["id": request.id, "error": "bad audio"])
            exit(3)
        }
        queue.push(Job(request: request, pcm: pcm.map { Float($0) / 32768 }))
    }
    exit(0) // stdin closed: the owner is gone.
}
reader.stackSize = 1 << 20
reader.start()

Memory.cacheLimit = 256 * 1024 * 1024
let loadStart = Date()
let engine: QwenEngine
do {
    engine = try QwenEngine(modelDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    reply(["event": "error", "message": "\(error)"])
    exit(1)
}
reply(["event": "ready", "load_ms": Int(Date().timeIntervalSince(loadStart) * 1000)])

while true {
    let job = queue.pop()
    let id = job.request.id
    let start = Date()
    let result = engine.transcribe(
        pcm: job.pcm,
        language: job.request.language,
        context: job.request.context,
        isCancelled: { queue.isCancelled(id) }
    )
    reply([
        "id": id,
        "text": result.text,
        "truncated": result.truncated,
        "cancelled": result.cancelled,
        "ms": Int(Date().timeIntervalSince(start) * 1000),
        "footprint_mb": footprintMB().current,
        "peak_mb": footprintMB().peak,
    ])
    queue.finish(id)
}

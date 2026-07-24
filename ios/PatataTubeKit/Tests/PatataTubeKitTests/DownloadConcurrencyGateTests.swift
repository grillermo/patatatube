import Foundation
import Testing
@testable import PatataTubeKit

private actor Recorder {
    private(set) var order: [Int] = []
    private(set) var active = 0
    private(set) var maxActive = 0

    func enter(_ id: Int) {
        active += 1
        maxActive = max(maxActive, active)
        order.append(id)
    }

    func leave() { active -= 1 }
}

@Suite("Download concurrency gate")
struct DownloadConcurrencyGateTests {

    @Test
    func capsConcurrentHolders() async {
        let gate = DownloadConcurrencyGate(limit: 2)
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<6 {
                group.addTask {
                    await gate.acquire()
                    await recorder.enter(id)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await recorder.leave()
                    gate.release()
                }
            }
        }

        #expect(await recorder.maxActive == 2)
    }

    @Test
    func releaseWithoutWaitersFreesSlot() async {
        let gate = DownloadConcurrencyGate(limit: 1)
        await gate.acquire()
        gate.release()
        // Second acquire must not deadlock now the slot is free.
        await gate.acquire()
        gate.release()
    }

    @Test
    func resumesWaitersInFIFOOrder() async {
        let gate = DownloadConcurrencyGate(limit: 1)
        let recorder = Recorder()

        await gate.acquire() // hold the only permit

        var tasks: [Task<Void, Never>] = []
        for id in 0..<3 {
            tasks.append(Task {
                await gate.acquire()
                await recorder.enter(id)
                gate.release()
            })
            // Stagger so each waiter enqueues before the next is spawned.
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        gate.release() // wake the chain
        for task in tasks { await task.value }

        #expect(await recorder.order == [0, 1, 2])
    }

    @Test
    func raisingLimitWakesQueuedWaiters() async {
        let gate = DownloadConcurrencyGate(limit: 1)
        await gate.acquire() // holds the single permit

        let started = Recorder()
        let waiter = Task {
            await gate.acquire()
            await started.enter(99)
            gate.release()
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await started.order.isEmpty) // still blocked

        gate.setLimit(2) // frees a slot for the waiter
        await waiter.value
        #expect(await started.order == [99])
        gate.release()
    }

    @Test
    func loweringLimitThrottlesNewStarts() async {
        let gate = DownloadConcurrencyGate(limit: 2)
        await gate.acquire()
        await gate.acquire() // 2 active
        gate.setLimit(1)

        let started = Recorder()
        let waiter = Task {
            await gate.acquire()
            await started.enter(1)
            gate.release()
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await started.order.isEmpty) // 2 active > new limit 1, blocked

        gate.release() // active drops to 1, still == limit, waiter stays blocked
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await started.order.isEmpty)

        gate.release() // active drops to 0 < limit, waiter proceeds
        await waiter.value
        #expect(await started.order == [1])
    }

    @Test
    func currentLimitReflectsSetLimit() {
        let gate = DownloadConcurrencyGate(limit: 3)
        #expect(gate.currentLimit == 3)
        gate.setLimit(1)
        #expect(gate.currentLimit == 1)
        gate.setLimit(0) // clamped to >= 1
        #expect(gate.currentLimit == 1)
    }
}

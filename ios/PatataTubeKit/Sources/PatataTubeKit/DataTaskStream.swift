import Foundation

/// One URLSession data task read as an async sequence of chunks.
///
/// Flow control is real. Past `highWater` unread bytes the task is
/// suspended, and it resumes once the reader drains below `lowWater`, so a
/// parked playback fetcher stops pulling from the network instead of filling
/// memory. Uses a per-task delegate, so it works on any session.
///
/// Ownership: `task.delegate = stream` and `stream.task = task` form a retain
/// cycle until the task completes. Every caller MUST call `cancel()` on every
/// exit path, including an early `break` or a throw out of `for try await`,
/// or a suspended or unfinished task keeps the stream alive.
///
/// `nextChunk()` supports a single concurrent reader.
final class DataTaskStream: NSObject, URLSessionDataDelegate, AsyncSequence, @unchecked Sendable {
    typealias Element = Data

    static let highWater = 4 * 1_048_576
    static let lowWater = 1_048_576

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var chunks: [Data] = []
    private var bufferedByteCount = 0
    private var isFinished = false
    private var isCancelled = false
    private var failure: Error?
    private var dataWaiter: CheckedContinuation<Void, Never>?
    private var isSuspended = false

    /// Starts `request` and returns once the response headers arrive.
    static func start(_ request: URLRequest, session: URLSession) async throws -> (HTTPURLResponse, DataTaskStream) {
        let stream = DataTaskStream()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.dataTask(with: request)
                task.delegate = stream
                let cancelledAlready = stream.lock.withLock { () -> Bool in
                    stream.task = task
                    if stream.isCancelled { return true }
                    stream.responseContinuation = continuation
                    return false
                }
                if cancelledAlready {
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            stream.cancel()
        }
        return (response, stream)
    }

    /// Stops the transfer and wakes a waiting reader. Safe to call twice.
    func cancel() {
        let (task, waiter) = lock.withLock { () -> (URLSessionDataTask?, CheckedContinuation<Void, Never>?) in
            isCancelled = true
            defer { dataWaiter = nil }
            return (self.task, dataWaiter)
        }
        task?.cancel()
        waiter?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { responseContinuation = nil }
            return responseContinuation
        }
        if let http = response as? HTTPURLResponse {
            continuation?.resume(returning: http)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (waiter, suspend) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Bool) in
            chunks.append(data)
            bufferedByteCount += data.count
            let waiter = dataWaiter
            dataWaiter = nil
            let suspend = !isSuspended && bufferedByteCount >= Self.highWater
            if suspend { isSuspended = true }
            return (waiter, suspend)
        }
        if suspend { dataTask.suspend() }
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, waiter) = lock.withLock {
            () -> (CheckedContinuation<HTTPURLResponse, Error>?, CheckedContinuation<Void, Never>?) in
            isFinished = true
            failure = error
            defer {
                responseContinuation = nil
                dataWaiter = nil
            }
            return (responseContinuation, dataWaiter)
        }
        // A cancel before the headers arrived is ours: report it as such.
        let wasCancelled = lock.withLock { isCancelled }
        continuation?.resume(throwing: wasCancelled ? CancellationError() : (error ?? URLError(.badServerResponse)))
        waiter?.resume()
    }

    // MARK: Reading

    struct Iterator: AsyncIteratorProtocol {
        let stream: DataTaskStream
        mutating func next() async throws -> Data? {
            try await stream.nextChunk()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(stream: self)
    }

    private enum Step {
        case chunk(Data, resume: URLSessionDataTask?)
        case end
        case fail(Error)
        case wait
    }

    /// The next chunk, nil at the end of the body. Bytes that arrived before
    /// a failure are all returned before the failure is thrown.
    func nextChunk() async throws -> Data? {
        while true {
            if Task.isCancelled {
                cancel()
                throw CancellationError()
            }
            let step = lock.withLock { () -> Step in
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    bufferedByteCount -= chunk.count
                    var resume: URLSessionDataTask?
                    if isSuspended, bufferedByteCount <= Self.lowWater {
                        isSuspended = false
                        resume = task
                    }
                    return .chunk(chunk, resume: resume)
                }
                if isCancelled { return .fail(CancellationError()) }
                if isFinished { return failure.map(Step.fail) ?? .end }
                return .wait
            }
            switch step {
            case .chunk(let chunk, let resume):
                resume?.resume()
                return chunk
            case .end:
                return nil
            case .fail(let error):
                throw error
            case .wait:
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let ready = lock.withLock { () -> Bool in
                            if !chunks.isEmpty || isFinished || isCancelled { return true }
                            dataWaiter = continuation
                            return false
                        }
                        if ready { continuation.resume() }
                    }
                } onCancel: {
                    self.cancel()
                }
            }
        }
    }
}

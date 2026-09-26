import Dispatch
import Darwin
import Foundation

final class StageRecordSignalCancellation {
    private let sources: [DispatchSourceSignal]
    private let originalSIGINTHandler: sig_t?
    private let originalSIGTERMHandler: sig_t?

    init(task: Task<Void, Error>) {
        originalSIGINTHandler = signal(SIGINT, SIG_IGN)
        originalSIGTERMHandler = signal(SIGTERM, SIG_IGN)

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interruptSource.setEventHandler { task.cancel() }
        terminateSource.setEventHandler { task.cancel() }
        sources = [interruptSource, terminateSource]
        sources.forEach { $0.resume() }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        _ = signal(SIGINT, originalSIGINTHandler ?? SIG_DFL)
        _ = signal(SIGTERM, originalSIGTERMHandler ?? SIG_DFL)
    }
}

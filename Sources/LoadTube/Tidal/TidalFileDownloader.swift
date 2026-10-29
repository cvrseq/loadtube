import Foundation

/// Скачивание одного файла с прогрессом через URLSessionDownloadTask.
final class TidalFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private let lock = NSLock()

    var onProgress: ((Int64, Int64) -> Void)?

    func download(
        _ url: URL,
        to destination: URL,
        headers: [String: String] = [:]
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.destination = destination

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: OperationQueue()
            )
            self.session = session

            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else {
            finish(.failure(TidalError.network("Download destination")))
            return
        }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(TidalHTTPError(status: http.statusCode)))
            return
        }

        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            lock.lock()
            let alreadyFinished = finished
            lock.unlock()
            if !alreadyFinished {
                finish(.failure(TidalError.network("Download incomplete")))
            }
            return
        }
        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(TidalError.cancelled))
        } else {
            finish(.failure(TidalError.network(error.localizedDescription)))
        }
    }

    // MARK: - Завершение

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

struct TidalHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? { "HTTP \(status)" }
}

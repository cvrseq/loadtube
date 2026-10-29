import Foundation

enum UpdateDownloadError: Error, Equatable {
    case cancelled
    case http(Int)
    case verifyFailed
    case incomplete
}

/// Скачивание DMG обновления с прогрессом.
final class UpdateFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private let lock = NSLock()

    var onProgress: ((Double) -> Void)?

    func download(_ url: URL, to destination: URL) async throws {
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
            request.setValue("LoadTube", forHTTPHeaderField: "User-Agent")
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
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else {
            finish(.failure(UpdateDownloadError.incomplete))
            return
        }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateDownloadError.http(http.statusCode)))
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
                finish(.failure(UpdateDownloadError.incomplete))
            }
            return
        }

        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(UpdateDownloadError.cancelled))
        } else {
            finish(.failure(error))
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

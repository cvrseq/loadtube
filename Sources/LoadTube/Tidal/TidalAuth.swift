import Foundation

/// Хранит сессию Tidal и выполняет device-code login / refresh.
/// Все операции сериализованы актором, поэтому параллельные загрузки
/// не начнут несколько refresh-запросов одновременно.
actor TidalAuth {
    static let shared = TidalAuth()

    private var session: TidalSession?
    private var loaded = false
    private var isRefreshing = false

    // MARK: - Публичное состояние

    func bootstrap() async -> TidalSession? {
        loadIfNeeded()
        guard let value = session else { return nil }
        if !value.isExpired {
            return value
        }
        do {
            return try await refresh(value)
        } catch TidalError.sessionExpired {
            clearSession()
            return nil
        } catch {
            // Офлайн или временная ошибка сервера не должны разлогинивать.
            return value
        }
    }

    func validSession(forceRefresh: Bool = false) async throws -> TidalSession {
        loadIfNeeded()
        guard let value = session else { throw TidalError.notSignedIn }
        if !forceRefresh && !value.isExpired {
            if value.sessionId == nil {
                let enriched = await enrich(value)
                if enriched.sessionId != nil {
                    session = enriched
                    save(enriched)
                }
                return enriched
            }
            return value
        }
        return try await refresh(value)
    }

    func currentAccount() async -> TidalAccount? {
        loadIfNeeded()
        return session?.account
    }

    func signOut() {
        session = nil
        loaded = true
        try? FileManager.default.removeItem(at: TidalConfig.sessionFile)
    }

    /// Сервер ответил 401 даже на «валидный» токен — сбрасываем сессию.
    func invalidate() {
        clearSession()
    }

    // MARK: - Device login

    func startDeviceLogin(preferredIndex: Int? = nil) async throws -> TidalDeviceLogin {
        var lastError: Error = TidalError.sessionExpired

        var order = Array(TidalConfig.credentials.indices)
        if let preferredIndex, order.contains(preferredIndex) {
            order.removeAll { $0 == preferredIndex }
            order.insert(preferredIndex, at: 0)
        }

        for index in order {
            let credential = TidalConfig.credentials[index]
            do {
                let response: DeviceAuthorizationResponse = try await postForm(
                    path: "device_authorization",
                    values: [
                        "client_id": credential.clientId,
                        "scope": TidalConfig.scope
                    ],
                    credential: credential,
                    useBasicAuth: false
                )

                let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
                let verification = response.verificationUriComplete ?? response.verificationUri
                let full = verification.hasPrefix("http") ? verification : "https://\(verification)"
                guard let url = URL(string: full) else { throw TidalError.server("Tidal login URL") }

                return TidalDeviceLogin(
                    deviceCode: response.deviceCode,
                    userCode: response.userCode,
                    verificationURL: url,
                    expiresAt: expiry,
                    interval: max(response.interval, 2),
                    credentialIndex: index
                )
            } catch TidalError.network {
                throw TidalError.network("Tidal login")
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    func pollLogin(_ login: TidalDeviceLogin) async throws -> TidalSession {
        guard login.credentialIndex < TidalConfig.credentials.count else {
            throw TidalError.sessionExpired
        }
        let credential = TidalConfig.credentials[login.credentialIndex]
        var interval = login.interval

        while Date() < login.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()

            do {
                let token: TokenResponse = try await postForm(
                    path: "token",
                    values: [
                        "client_id": credential.clientId,
                        "device_code": login.deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "scope": TidalConfig.scope
                    ],
                    credential: credential,
                    useBasicAuth: true
                )
                var newSession = try makeSession(token, credentialIndex: login.credentialIndex)
                newSession = await enrich(newSession)
                save(newSession)
                session = newSession
                loaded = true
                return newSession
            } catch TidalError.pendingAuthorization {
                continue
            } catch TidalError.slowDown {
                interval += 5
                continue
            } catch TidalError.rateLimited(let seconds) {
                interval = max(interval, seconds)
                continue
            } catch TidalError.sessionExpired {
                throw TidalError.sessionExpired
            } catch {
                // 400/1002 и прочие временные ответы — ждём дальше.
                if case TidalError.server = error {
                    continue
                }
                throw error
            }
        }

        throw TidalError.sessionExpired
    }

    // MARK: - Refresh

    private func refresh(_ old: TidalSession) async throws -> TidalSession {
        if isRefreshing {
            // Пока другой запрос обновлял токен, дождёмся результата.
            for _ in 0..<60 where isRefreshing {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if let current = session, !current.isExpired {
                return current
            }
            throw TidalError.sessionExpired
        }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let refreshToken = old.refreshToken, !refreshToken.isEmpty else {
            clearSession()
            throw TidalError.sessionExpired
        }
        guard old.credentialIndex < TidalConfig.credentials.count else {
            clearSession()
            throw TidalError.sessionExpired
        }
        let credential = TidalConfig.credentials[old.credentialIndex]

        do {
            let token: TokenResponse = try await postForm(
                path: "token",
                values: [
                    "client_id": credential.clientId,
                    "refresh_token": refreshToken,
                    "grant_type": "refresh_token",
                    "scope": TidalConfig.scope
                ],
                credential: credential,
                useBasicAuth: true
            )
            var newSession = try makeSession(token, credentialIndex: old.credentialIndex)
            if newSession.countryCode.isEmpty {
                newSession.countryCode = old.countryCode
            }
            if newSession.userId == 0 {
                newSession.userId = old.userId
            }
            if newSession.refreshToken == nil || newSession.refreshToken?.isEmpty == true {
                newSession.refreshToken = old.refreshToken
            }
            newSession = await enrich(newSession)
            save(newSession)
            session = newSession
            loaded = true
            return newSession
        } catch TidalError.sessionExpired {
            clearSession()
            throw TidalError.sessionExpired
        } catch {
            // Сеть/429/5xx: сессию не трогаем, пользователь сможет повторить.
            throw error
        }
    }

    // MARK: - HTTP

    private func postForm<T: Decodable>(
        path: String,
        values: [String: String],
        credential: TidalCredential,
        useBasicAuth: Bool
    ) async throws -> T {
        guard let url = URL(string: TidalConfig.authBase.absoluteString + "/" + path) else {
            throw TidalError.server("Tidal auth URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(TidalConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = formBody(values)

        if useBasicAuth {
            let raw = "\(credential.clientId):\(credential.clientSecret)"
            let encoded = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TidalError.network("Tidal auth")
        }

        // OAuth pending/slow_down приходят с HTTP 400.
        if http.statusCode == 400 {
            let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            let code = (error?.error ?? "").lowercased()
            if code.contains("pending") { throw TidalError.pendingAuthorization }
            if code.contains("slow_down") { throw TidalError.slowDown }
            if code.contains("expired") { throw TidalError.sessionExpired }
            if code.contains("access_denied") { throw TidalError.sessionExpired }
            if code.contains("invalid_grant") || code.contains("invalid_client") {
                throw TidalError.sessionExpired
            }
            if let sub = error?.subStatus, sub == 1002 { throw TidalError.pendingAuthorization }
            throw TidalError.server(error?.errorDescription ?? "Tidal auth (400)")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw TidalError.sessionExpired
        }
        if http.statusCode == 429 {
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 20
            throw TidalError.rateLimited(seconds: max(retry, 5))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TidalError.server("Tidal auth (\(http.statusCode))")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TidalError.server("Tidal auth response")
        }
    }

    private func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let pairs = values.map { key, value -> String in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    // MARK: - Session

    private func makeSession(_ token: TokenResponse, credentialIndex: Int) throws -> TidalSession {
        guard let accessToken = token.accessToken, !accessToken.isEmpty else {
            throw TidalError.sessionExpired
        }
        let now = Date().timeIntervalSince1970
        return TidalSession(
            userId: token.user?.userId ?? 0,
            countryCode: token.user?.countryCode ?? "",
            accessToken: accessToken,
            refreshToken: token.refreshToken,
            expiresAt: now + TimeInterval(token.expiresIn ?? 3600),
            credentialIndex: credentialIndex
        )
    }

    /// Иногда token endpoint не отдаёт countryCode/userId. Дозапрашиваем
    /// /sessions, чтобы регион и аккаунт были корректными.
    private func enrich(_ value: TidalSession) async -> TidalSession {
        guard value.countryCode.isEmpty || value.userId == 0 || value.sessionId == nil else {
            return value
        }
        guard let url = URL(string: "https://api.tidal.com/v1/sessions") else { return value }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(value.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TidalConfig.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let info = try? JSONDecoder().decode(TidalSessionInfo.self, from: data) else {
            return value
        }
        var result = value
        if let userId = info.userId, userId > 0 { result.userId = userId }
        if let country = info.countryCode, !country.isEmpty { result.countryCode = country }
        if let sessionId = info.sessionId, !sessionId.isEmpty { result.sessionId = sessionId }
        return result
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let stored = readSession() {
            session = stored
            return
        }
        if let legacy = readLegacySession() {
            session = legacy
            save(legacy)
        }
    }

    private func readSession() -> TidalSession? {
        guard let data = try? Data(contentsOf: TidalConfig.sessionFile) else { return nil }
        return try? JSONDecoder().decode(TidalSession.self, from: data)
    }

    /// Импорт входа из tidal-dl, чтобы существующим пользователям
    /// не приходилось авторизовываться заново.
    private func readLegacySession() -> TidalSession? {
        guard let encoded = try? Data(contentsOf: TidalConfig.legacyTokenFile) else { return nil }
        let decodedData: Data
        if let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            decodedData = decoded
        } else {
            decodedData = encoded
        }
        guard let object = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any],
              let accessToken = object["accessToken"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let userId = (object["userid"] as? NSNumber)?.intValue
            ?? Int(object["userid"] as? String ?? "")
            ?? 0
        let country = object["countryCode"] as? String ?? ""
        let refresh = object["refreshToken"] as? String
        let expiresAfter = (object["expiresAfter"] as? NSNumber)?.doubleValue ?? 0
        return TidalSession(
            userId: userId,
            countryCode: country,
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: expiresAfter,
            credentialIndex: 0
        )
    }

    private func save(_ value: TidalSession) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: TidalConfig.sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: TidalConfig.sessionFile, options: .atomic)
            try? fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: TidalConfig.sessionFile.path
            )
        } catch {
            // Ошибка записи не должна ломать текущую сессию.
        }
    }

    private func clearSession() {
        session = nil
        loaded = true
        try? FileManager.default.removeItem(at: TidalConfig.sessionFile)
    }
}

// MARK: - Внутренние ответы OAuth

private struct DeviceAuthorizationResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int
}

private struct TokenUser: Decodable {
    let userId: Int?
    let countryCode: String?
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let user: TokenUser?
    let status: Int?
    let subStatus: Int?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
        case status
        case subStatus = "sub_status"
        case error
        case errorDescription = "error_description"
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?
    let status: Int?
    let subStatus: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case status
        case subStatus = "sub_status"
    }
}

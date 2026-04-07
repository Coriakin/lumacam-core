import Foundation
import Network
import LumaCamCore

struct NativeRTSPControlPlaneContext: Sendable {
    let endpointURL: URL
    let username: String?
    let password: String?
    let requestedTransport: RTSPTransport
    let resolvedTransport: RTSPTransport
    let userAgent: String
}

struct NativeRTSPControlPlaneSuccess: Sendable {
    let sessionIdentifier: String
    let describeBody: Data
    let selectedVideoTrack: NativeRTSPSelectedVideoTrack
    let negotiatedTransport: RTSPTransportAlternative
    let playURL: URL
    let connection: NativeRTSPConnection
}

/// Control plane runs on a single async task; socket access is not shared across tasks.
final class NativeRTSPControlPlaneExecutor: @unchecked Sendable {
    private let context: NativeRTSPControlPlaneContext
    private let connection: NativeRTSPConnection
    private var sessionIdentifier: String?

    init(context: NativeRTSPControlPlaneContext) {
        self.context = context
        self.connection = NativeRTSPConnection(endpointURL: context.endpointURL)
    }

    func run() async throws -> NativeRTSPControlPlaneSuccess {
        do {
            try await connection.connect()
            LumaCamDiagnostics.log(
                "native rtsp control plane starting endpoint=\(context.endpointURL.absoluteString) requestedTransport=\(context.requestedTransport.displayName) resolvedTransport=\(context.resolvedTransport.displayName)",
                level: .debug,
                category: "rtsp.native"
            )
            _ = try await perform(method: .options, additionalHeaders: [], body: nil)
            let describeResponse = try await perform(
                method: .describe,
                additionalHeaders: [RTSPHeader("Accept", "application/sdp")],
                body: nil
            )
            if let session = describeResponse.sessionIdentifier {
                sessionIdentifier = session
            }
            guard let describeBody = describeResponse.body, !describeBody.isEmpty else {
                throw PlaybackError.transportFailure("DESCRIBE completed but no SDP body was returned.")
            }
            let sessionDescription = try parseSessionDescription(from: describeBody)
            let selectedTrack = try selectVideoTrack(in: sessionDescription)
            let negotiatedTransport = try await performSetup(for: selectedTrack)
            let playURL = try await performPlay(for: selectedTrack)
            guard let sessionIdentifier else {
                throw PlaybackError.transportFailure("RTSP SETUP/PLAY completed without a Session header.")
            }
            return NativeRTSPControlPlaneSuccess(
                sessionIdentifier: sessionIdentifier,
                describeBody: describeBody,
                selectedVideoTrack: selectedTrack,
                negotiatedTransport: negotiatedTransport,
                playURL: playURL,
                connection: connection
            )
        } catch let error as PlaybackError {
            connection.close()
            throw error
        } catch let error as SDPParserError {
            connection.close()
            throw PlaybackError.transportFailure("Unable to parse SDP: \(error)")
        } catch let error as SDPTrackSelectionError {
            connection.close()
            throw PlaybackError.transportFailure("Unable to select a playable video track: \(error)")
        } catch let error as RTSPTransportHeaderError {
            connection.close()
            throw PlaybackError.transportFailure("Unable to negotiate RTSP transport: \(error)")
        } catch let error as NWError {
            connection.close()
            throw mapNetworkError(error)
        } catch {
            connection.close()
            throw PlaybackError.transportFailure(error.localizedDescription)
        }
    }

    private func perform(
        method: RTSPMethod,
        requestURL: URL? = nil,
        additionalHeaders: [RTSPHeader],
        body: Data?
    ) async throws -> RTSPResponse {
        let requestURL = requestURL ?? context.endpointURL
        let response = try await connection.sendRequest(
            method: method,
            url: requestURL,
            userAgent: context.userAgent,
            sessionIdentifier: sessionIdentifier,
            additionalHeaders: additionalHeaders,
            body: body,
            authorizationHeader: nil
        )
        if response.statusCode == 401 {
            return try await retryAuthenticated(
                method: method,
                requestURL: requestURL,
                additionalHeaders: additionalHeaders,
                body: body,
                response: response
            )
        }
        return try validate(response, method: method)
    }

    private func retryAuthenticated(
        method: RTSPMethod,
        requestURL: URL,
        additionalHeaders: [RTSPHeader],
        body: Data?,
        response: RTSPResponse
    ) async throws -> RTSPResponse {
        logVerboseRTSPDebug(
            """
            401 Unauthorized for \(method.rawValue) \(requestURL.absoluteString)
            \(rtspResponseDebugDump(response))
            """
        )

        guard let username = context.username, let password = context.password else {
            logVerboseRTSPDebug(
                "cannot build Authorization: missing credentials in context (hasUser=\(context.username != nil) hasPassword=\(context.password != nil))"
            )
            throw PlaybackError.authenticationFailed
        }

        logPlaintextCredentialsIfEnabled(username: username, password: password)

        var challengeSource = response
        let maxDigestAttempts = 4

        for attempt in 1...maxDigestAttempts {
            let wwwValues = challengeSource.headerValues(named: "WWW-Authenticate")
            guard let challenge = RTSPAuthenticator.preferredChallenge(from: wwwValues) else {
                logVerboseRTSPDebug(
                    "no usable Basic/Digest challenge in WWW-Authenticate. Raw values: \(wwwValues.map { $0 }.joined(separator: " | "))"
                )
                throw PlaybackError.authenticationFailed
            }

            logVerboseRTSPDebug(
                """
                digest attempt \(attempt)/\(maxDigestAttempts) selected challenge scheme=\(String(describing: challenge.scheme)) realm=\(challenge.realm ?? "nil") nonce=\(challenge.nonce.map { String($0.prefix(12)) + "…" } ?? "nil") qop=\(challenge.qop ?? "nil") algorithm=\(challenge.algorithm ?? "nil") digestURI=\(requestURL.absoluteString)
                """
            )

            if let reason = RTSPAuthenticator.digestBuildFailureReason(for: challenge) {
                logVerboseRTSPDebug("digest would fail: \(reason)")
            }

            guard let authorizationHeader = RTSPAuthenticator.authorizationHeaderValue(
                username: username,
                password: password,
                method: method.rawValue,
                uri: requestURL.absoluteString,
                challenge: challenge
            ) else {
                logVerboseRTSPDebug("authorizationHeaderValue returned nil (see digest would fail above)")
                throw PlaybackError.authenticationFailed
            }

            if LumaCamDebugFlags.logRTSPPlaintextSecrets {
                LumaCamDiagnostics.log(
                    "Authorization header (full): \(authorizationHeader)",
                    level: .debug,
                    category: "rtsp.secrets"
                )
            } else if LumaCamDebugFlags.verboseRTSPProtocolLog {
                LumaCamDiagnostics.log(
                    "Authorization header: \(redactAuthorizationHeaderForLog(authorizationHeader))",
                    level: .debug,
                    category: "rtsp.debug"
                )
            }

            let authenticatedResponse = try await connection.sendRequest(
                method: method,
                url: requestURL,
                userAgent: context.userAgent,
                sessionIdentifier: sessionIdentifier,
                additionalHeaders: additionalHeaders,
                body: body,
                authorizationHeader: authorizationHeader
            )

            if authenticatedResponse.statusCode != 401 {
                return try validate(authenticatedResponse, method: method)
            }

            if attempt < maxDigestAttempts {
                logVerboseRTSPDebug(
                    """
                    digest attempt \(attempt) returned 401; retrying with fresh WWW-Authenticate nonce if present
                    \(rtspResponseDebugDump(authenticatedResponse))
                    """
                )
            }
            challengeSource = authenticatedResponse
        }

        logVerboseRTSPDebug(
            """
            auth still failing after \(maxDigestAttempts) digest attempt(s) for \(method.rawValue)
            \(rtspResponseDebugDump(challengeSource))
            """
        )
        return try validate(challengeSource, method: method)
    }

    private func validate(_ response: RTSPResponse, method: RTSPMethod) throws -> RTSPResponse {
        if let session = response.sessionIdentifier {
            sessionIdentifier = session
            LumaCamDiagnostics.log(
                "rtsp response session header parsed session=\(session) method=\(method.rawValue)",
                level: .debug,
                category: "rtsp.native"
            )
        }

        switch response.statusCode {
        case 200...299:
            return response
        case 401:
            // Exhaustive digest retries log in `retryAuthenticated`; avoid duplicate lines here.
            throw PlaybackError.authenticationFailed
        case 403:
            logVerboseRTSPDebug(
                """
                auth still failing after Authorization retry: \(response.statusCode) for \(method.rawValue)
                \(rtspResponseDebugDump(response))
                """
            )
            throw PlaybackError.authenticationFailed
        case 404:
            throw PlaybackError.transportFailure("The RTSP endpoint returned 404 for \(method.rawValue).")
        case 500...599:
            throw PlaybackError.transportFailure("The RTSP server returned \(response.statusCode) for \(method.rawValue).")
        default:
            throw PlaybackError.transportFailure("The RTSP server returned \(response.statusCode) for \(method.rawValue). \(response.reasonPhrase)")
        }
    }

    private func parseSessionDescription(from body: Data) throws -> SDPSessionDescription {
        try SDPParser.parse(body)
    }

    private func selectVideoTrack(in sessionDescription: SDPSessionDescription) throws -> NativeRTSPSelectedVideoTrack {
        let selection = try SDPTrackSelector.selectPlayableH264VideoTrack(
            in: sessionDescription,
            baseRTSPURL: context.endpointURL
        )
        return NativeRTSPSelectedVideoTrack(selection: selection)
    }

    private func performSetup(for selectedTrack: NativeRTSPSelectedVideoTrack) async throws -> RTSPTransportAlternative {
        let transportHeaderValue = "RTP/AVP/TCP;unicast;interleaved=0-1"
        let response = try await perform(
            method: .setup,
            requestURL: selectedTrack.controlURL,
            additionalHeaders: [RTSPHeader("Transport", transportHeaderValue)],
            body: nil
        )

        guard let rawTransportHeader = response.headerValue(named: "Transport") else {
            throw PlaybackError.transportFailure("RTSP SETUP succeeded but no Transport header was returned.")
        }

        let header = try RTSPTransportHeader.parse(rawTransportHeader)
        let negotiatedTransport = try header.singleTCPInterleavedAlternative()
        guard sessionIdentifier != nil else {
            throw PlaybackError.transportFailure("RTSP SETUP succeeded but no Session header was returned.")
        }

        LumaCamDiagnostics.log(
            "native rtsp setup negotiated session=\(sessionIdentifier ?? "none") interleaved=\(channelDescription(negotiatedTransport.interleavedChannelPair)) transport=\(rawTransportHeader)",
            level: .debug,
            category: "rtsp.native"
        )
        return negotiatedTransport
    }

    private func performPlay(for selectedTrack: NativeRTSPSelectedVideoTrack) async throws -> URL {
        let preferredURL = selectedTrack.playbackControlURL
        do {
            _ = try await perform(
                method: .play,
                requestURL: preferredURL,
                additionalHeaders: [RTSPHeader("Range", "npt=0.000-")],
                body: nil
            )
            return preferredURL
        } catch let error as PlaybackError {
            guard preferredURL != context.endpointURL else {
                throw error
            }

            _ = try await perform(
                method: .play,
                requestURL: context.endpointURL,
                additionalHeaders: [RTSPHeader("Range", "npt=0.000-")],
                body: nil
            )
            return context.endpointURL
        }
    }

    private func channelDescription(_ pair: RTSPTransportChannelPair?) -> String {
        guard let pair else {
            return "unknown"
        }

        return "\(pair.first)-\(pair.second)"
    }

    private func logVerboseRTSPDebug(_ message: String) {
        guard LumaCamDebugFlags.verboseRTSPProtocolLog else { return }
        LumaCamDiagnostics.log(message, level: .debug, category: "rtsp.debug")
    }

    private func logPlaintextCredentialsIfEnabled(username: String, password: String) {
        guard LumaCamDebugFlags.logRTSPPlaintextSecrets else { return }
        LumaCamDiagnostics.log(
            "plaintext credentials username=\(username) password=\(password)",
            level: .debug,
            category: "rtsp.secrets"
        )
    }

    private func mapNetworkError(_ error: NWError) -> PlaybackError {
        switch error {
        case let .posix(posixError):
            switch posixError {
            case .ECONNREFUSED, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ETIMEDOUT, .ECONNRESET:
                return .networkUnavailable
            default:
                return .transportFailure("Network error: \(error)")
            }
        case .dns(_):
            return .networkUnavailable
        default:
            return .transportFailure("Network error: \(error)")
        }
    }
}

final class NativeRTSPConnection: @unchecked Sendable {
    private let endpointURL: URL
    private let queue = DispatchQueue(label: "se.andreasbjorn.lumacam.native-rtsp.connection")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var receiveBufferOffset = 0
    private let connectTimeout: Duration = .seconds(10)
    private let receiveBufferCompactThreshold = 128 * 1024
    private var cseq = 1

    init(endpointURL: URL) {
        self.endpointURL = endpointURL
    }

    func connect() async throws {
        guard let host = endpointURL.host, !host.isEmpty else {
            throw PlaybackError.invalidEndpoint
        }

        let portValue = endpointURL.port ?? 554
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw PlaybackError.invalidEndpoint
        }

        let newConnection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection = newConnection
        cseq = 1

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let resumeGate = OneShotResumeGate()

                        newConnection.stateUpdateHandler = { [weak self] state in
                            switch state {
                            case .ready:
                                resumeGate.resumeOnce {
                                    newConnection.stateUpdateHandler = nil
                                    continuation.resume()
                                }
                            case let .failed(error):
                                resumeGate.resumeOnce {
                                    self?.connection = nil
                                    newConnection.stateUpdateHandler = nil
                                    continuation.resume(throwing: Self.mapNetworkError(error))
                                }
                            case .cancelled:
                                resumeGate.resumeOnce {
                                    self?.connection = nil
                                    newConnection.stateUpdateHandler = nil
                                    continuation.resume(throwing: PlaybackError.networkUnavailable)
                                }
                            default:
                                break
                            }
                        }

                        newConnection.start(queue: self.queue)
                    }
                }

                group.addTask { [connectTimeout] in
                    try await Task.sleep(for: connectTimeout)
                    throw PlaybackError.transportFailure("RTSP connect timed out after \(Int(connectTimeout.components.seconds))s.")
                }

                do {
                    guard let _ = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return
                } catch {
                    group.cancelAll()
                    newConnection.stateUpdateHandler = nil
                    newConnection.cancel()
                    connection = nil
                    throw error
                }
            }
        } onCancel: {
            newConnection.stateUpdateHandler = nil
            newConnection.cancel()
            connection = nil
        }
    }

    private func send(_ request: RTSPRequest, authorizationHeader: String? = nil) async throws -> RTSPResponse {
        guard connection != nil else {
            throw PlaybackError.networkUnavailable
        }

        let serialized = request.serialized(authorizationHeader: authorizationHeader)
        logOutboundRTSP(serialized: serialized)
        try await sendData(serialized)
        let response = try await readResponse()
        logInboundRTSP(response)
        return response
    }

    func sendRequest(
        method: RTSPMethod,
        url: URL,
        userAgent: String,
        sessionIdentifier: String?,
        additionalHeaders: [RTSPHeader],
        body: Data?,
        authorizationHeader: String?
    ) async throws -> RTSPResponse {
        var headers = [
            RTSPHeader("CSeq", String(cseq)),
            RTSPHeader("User-Agent", userAgent),
        ]
        if let sessionIdentifier {
            headers.append(RTSPHeader("Session", sessionIdentifier))
        }
        headers.append(contentsOf: additionalHeaders)
        cseq += 1

        return try await send(RTSPRequest(method: method, url: url, headers: headers, body: body), authorizationHeader: authorizationHeader)
    }

    func sendKeepalive(
        method: RTSPMethod = .options,
        userAgent: String,
        sessionIdentifier: String,
        url: URL
    ) async throws -> RTSPResponse {
        let body: Data? = method == .getParameter ? Data() : nil
        return try await sendRequest(
            method: method,
            url: url,
            userAgent: userAgent,
            sessionIdentifier: sessionIdentifier,
            additionalHeaders: [],
            body: body,
            authorizationHeader: nil
        )
    }

    func sendTeardown(
        userAgent: String,
        sessionIdentifier: String,
        url: URL
    ) async throws -> RTSPResponse {
        try await sendRequest(
            method: .teardown,
            url: url,
            userAgent: userAgent,
            sessionIdentifier: sessionIdentifier,
            additionalHeaders: [],
            body: nil,
            authorizationHeader: nil
        )
    }

    func close() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        receiveBufferOffset = 0
        cseq = 1
    }

    func readInterleavedFrame() async throws -> RTSPInterleavedFrame {
        while true {
            compactReceiveBufferIfNeeded()
            switch RTSPInterleavedFrameParser.parse(from: receiveBuffer.suffix(from: receiveBuffer.index(receiveBuffer.startIndex, offsetBy: receiveBufferOffset))) {
            case let .complete(frame, consumedBytes):
                receiveBufferOffset += consumedBytes
                return frame
            case .incomplete:
                let chunk = try await receiveChunk()
                if !chunk.isEmpty {
                    receiveBuffer.append(chunk)
                }
            case let .invalid(error):
                throw PlaybackError.transportFailure("Unexpected data while waiting for RTSP interleaved RTP: \(error)")
            }

            if receiveBuffer.count - receiveBufferOffset > 1_048_576 {
                throw PlaybackError.transportFailure("RTSP interleaved frame buffer exceeded the maximum allowed size.")
            }
        }
    }

    private func sendData(_ data: Data) async throws {
        guard let connection else {
            throw PlaybackError.networkUnavailable
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeGate = OneShotResumeGate()
                connection.send(content: data, completion: .contentProcessed { error in
                    resumeGate.resumeOnce {
                        if let error {
                            continuation.resume(throwing: Self.mapNetworkError(error))
                        } else {
                            continuation.resume()
                        }
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func readResponse() async throws -> RTSPResponse {
        while true {
            compactReceiveBufferIfNeeded()
            // Must read from the socket before the first parse; an empty buffer is not incomplete — it means we have not received yet.
            if receiveBuffer.count == receiveBufferOffset {
                let chunk = try await receiveChunk()
                receiveBuffer.append(chunk)
            }

            do {
                let available = receiveBuffer.suffix(from: receiveBuffer.index(receiveBuffer.startIndex, offsetBy: receiveBufferOffset))
                if let parsed = try RTSPParser.parseResponse(from: available) {
                    receiveBufferOffset += parsed.consumedBytes
                    return parsed.response
                }

                let chunk = try await receiveChunk()
                if !chunk.isEmpty {
                    receiveBuffer.append(chunk)
                }
            } catch let parserError as RTSPParserError {
                switch parserError {
                case .missingHeaderTerminator, .bodyTooShort:
                    let chunk = try await receiveChunk()
                    if !chunk.isEmpty {
                        receiveBuffer.append(chunk)
                    }
                default:
                    throw PlaybackError.transportFailure("Unable to parse RTSP response: \(parserError)")
                }
            } catch {
                throw PlaybackError.transportFailure(error.localizedDescription)
            }

            if receiveBuffer.count - receiveBufferOffset > 1_048_576 {
                throw PlaybackError.transportFailure("RTSP response exceeded the maximum allowed buffered size.")
            }
        }
    }

    private func compactReceiveBufferIfNeeded() {
        guard receiveBufferOffset > 0 else { return }
        guard receiveBufferOffset >= receiveBufferCompactThreshold || receiveBufferOffset == receiveBuffer.count else { return }
        receiveBuffer.removeSubrange(0..<receiveBufferOffset)
        receiveBufferOffset = 0
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else {
            throw PlaybackError.networkUnavailable
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let resumeGate = OneShotResumeGate()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    resumeGate.resumeOnce {
                        if let error {
                            continuation.resume(throwing: Self.mapNetworkError(error))
                            return
                        }

                        if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                            return
                        }

                        if isComplete {
                            continuation.resume(throwing: PlaybackError.networkUnavailable)
                            return
                        }

                        continuation.resume(throwing: PlaybackError.transportFailure("RTSP connection yielded no data."))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func mapNetworkError(_ error: NWError) -> PlaybackError {
        switch error {
        case let .posix(posixError):
            switch posixError {
            case .ECONNREFUSED, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ETIMEDOUT, .ECONNRESET:
                return .networkUnavailable
            default:
                return .transportFailure("Network error: \(error)")
            }
        case .dns(_):
            return .networkUnavailable
        default:
            return .transportFailure("Network error: \(error)")
        }
    }
}

private func rtspResponseDebugDump(_ response: RTSPResponse) -> String {
    var lines: [String] = ["status=\(response.statusLine)"]
    for header in response.headers {
        lines.append("  \(header.name): \(header.value)")
    }
    if let body = response.body {
        let preview = String(data: body.prefix(512), encoding: .utf8) ?? "(non-UTF8 binary)"
        lines.append("  body: \(body.count) bytes, preview=\(preview)")
    } else {
        lines.append("  body: none")
    }
    return lines.joined(separator: "\n")
}

private func redactAuthorizationHeaderForLog(_ value: String) -> String {
    if value.hasPrefix("Digest ") {
        return "Digest … [redacted — enable Plaintext RTSP secrets in Settings]"
    }
    if value.hasPrefix("Basic ") {
        return "Basic … [redacted]"
    }
    return "[redacted]"
}

private func redactAuthorizationLinesInRTSPMessage(_ text: String) -> String {
    text.split(separator: "\r\n", omittingEmptySubsequences: false)
        .map { line -> String in
            let s = String(line)
            if s.lowercased().hasPrefix("authorization:") {
                return "Authorization: [redacted — enable Plaintext RTSP secrets in Settings]"
            }
            return s
        }
        .joined(separator: "\r\n")
}

private func logOutboundRTSP(serialized: Data) {
    guard LumaCamDebugFlags.verboseRTSPProtocolLog else { return }
    let text: String
    if LumaCamDebugFlags.logRTSPPlaintextSecrets, let s = String(data: serialized, encoding: .utf8) {
        text = s
    } else if let s = String(data: serialized, encoding: .utf8) {
        text = redactAuthorizationLinesInRTSPMessage(s)
    } else {
        text = "(non-UTF8, \(serialized.count) bytes)"
    }
    LumaCamDiagnostics.log(
        "RTSP outbound (\(serialized.count) bytes)\n\(text)",
        level: .debug,
        category: "rtsp.debug"
    )
}

private func logInboundRTSP(_ response: RTSPResponse) {
    guard LumaCamDebugFlags.verboseRTSPProtocolLog else { return }
    LumaCamDiagnostics.log(
        "RTSP inbound\n\(rtspResponseDebugDump(response))",
        level: .debug,
        category: "rtsp.debug"
    )
}

private final class OneShotResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resumeOnce(_ work: () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return }
        hasResumed = true
        work()
    }
}

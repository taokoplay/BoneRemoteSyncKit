import Foundation
import BoneRemoteSyncCore

extension OneDriveSource {
    func access(generation gen: UUID, client: ODHTTPClient, refreshExpected: String? = nil) async throws -> String {
        try check(gen)
        guard let token else { throw RemoteSyncError.notConnected }
        if let expected = refreshExpected, expected != token.accessToken { return token.accessToken }
        if refreshExpected == nil, token.expiresAt.timeIntervalSinceNow > 60 { return token.accessToken }
        guard let refresh = token.refreshToken, !refresh.isEmpty else {
            throw RemoteSyncError.authenticationFailed(reason: "OneDrive 需要重新授权")
        }
        let pending: (id: UUID, task: Task<OneDriveToken, Error>)
        if let refreshing { pending = refreshing }
        else {
            let oauth = OneDriveOAuth(configuration: configuration, endpoints: endpoints)
            pending = (UUID(), Task { try await oauth.refresh(refresh, client: client) })
            refreshing = pending
        }
        do {
            let new = try await pending.task.value
            // A waiter may be cancelled, but a completed refresh may already have rotated the
            // server credential. Commit once for the still-current account before honoring that
            // waiter's cancellation; never discard a newly issued refresh token and reuse the old one.
            guard generation == gen, self.client != nil else { throw RemoteSyncError.cancelled }
            if refreshing?.id == pending.id {
                // Synchronous commit callback: no actor reentrancy can switch accounts mid-persistence.
                do { try onTokenRefresh?(new) }
                catch { invalidate(); throw RemoteSyncError.authenticationFailed(reason: "OneDrive 更新凭据未能安全保存，请重新授权") }
                self.token = new; refreshing = nil
            }
            try check(gen)
            guard let current = self.token else { throw RemoteSyncError.notConnected }
            return current.accessToken
        } catch {
            // Failure may have occurred after the server rotated a refresh token. Fail closed
            // rather than repeatedly submitting a potentially consumed credential. Host must
            // reconnect with a known current token or perform interactive authorization.
            if generation == gen, refreshing?.id == pending.id { invalidate() }
            throw ODHTTPClient.mapped(error)
        }
    }
    func graph(
        _ url: URL,
        generation gen: UUID,
        client: ODHTTPClient,
        path: String = "/",
        method: String = "GET",
        json: Data? = nil,
        body: ODUploadBody? = nil,
        contentType: String? = nil,
        uploadProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> ODHTTPResponse {
        do {
            try ODLocation.validateGraph(url, base: endpoints.graph)
            var bearer = try await access(generation: gen, client: client)
            for attempt in 0...1 {
                try check(gen)
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                if let json {
                    request.httpBody = json
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let result = try await client.send(request, body: body, uploadProgress: uploadProgress)
                try check(gen)
                if result.response.statusCode == 401, attempt == 0 {
                    bearer = try await access(generation: gen, client: client, refreshExpected: bearer); continue
                }
                try ODHTTPClient.validate(result.response, path: path)
                return result
            }
            throw RemoteSyncError.authenticationFailed(reason: "OneDrive 需要重新授权")
        } catch { throw ODHTTPClient.mapped(error) }
    }
    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteSyncError.unsupported(operation: "OneDrive JSON 响应无效") }
    }
    func item(path: String, context: ODContext) async throws -> ODItem {
        let normalized = RemotePath.normalize(path)
        let url = try ODLocation.path(normalized, drive: context.drive, base: endpoints.graph)
        let response = try await graph(url, generation: context.generation, client: context.client, path: normalized)
        let value = try decode(ODItem.self, response.data)
        try value.validate(drive: context.drive, path: normalized)
        return value
    }
    func item(id: String, path: String?, context: ODContext) async throws -> ODItem {
        let itemID = try ODLocation.itemID(id, drive: context.drive)
        let url = ODLocation.item(itemID, drive: context.drive, base: endpoints.graph)
        let response = try await graph(url, generation: context.generation, client: context.client, path: path ?? "/")
        let value = try decode(ODItem.self, response.data)
        try value.validate(drive: context.drive, path: path ?? "/")
        guard value.id == itemID else { throw RemoteSyncError.conflict(path: path ?? "/") }
        return value
    }
}

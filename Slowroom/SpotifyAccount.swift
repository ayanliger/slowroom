import AuthenticationServices
import Foundation
import Observation
import Security
import UIKit

@MainActor
@Observable
final class SpotifyAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    var stage: String?
    var error: String?
    var playbackReady = false
    private var tokens: Tokens? = TokenStore.load()
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var browser: ASWebAuthenticationSession?
    @ObservationIgnored private var browserID: UUID?

    var isSignedIn: Bool { tokens != nil }
    var isSigningIn: Bool { loginTask != nil }
    private static let clientID = "65b708073fc0480ea92a077233ca87bd"

    func signIn() {
        guard loginTask == nil else { return }
        error = nil
        stage = "Opening Spotify sign-in"
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { closeBrowser(); loginTask = nil; stage = nil }
            do {
                let (data, status) = try await Self.post("oauth2/device/authorize", values: [
                    "client_id": Self.clientID, "scope": "streaming", "intent": "login"
                ])
                guard status == 200 else { throw SpotifyError.message("Spotify could not start sign-in (HTTP \(status)).") }
                let authorization = try JSONDecoder().decode(DeviceAuthorization.self, from: data)
                let url = authorization.verification_uri_complete ?? authorization.verification_uri
                guard url.scheme == "https", let host = url.host,
                      ["spotify.com", "www.spotify.com", "accounts.spotify.com"].contains(host) else {
                    throw SpotifyError.message("Spotify returned an unexpected sign-in page.")
                }
                try openBrowser(url)
                stage = "Waiting for Spotify sign-in"
                let envelope = try await poll(authorization)
                closeBrowser()
                let saved = try Tokens(envelope: envelope, previous: nil)
                try TokenStore.save(saved)
                tokens = saved
                stage = "Checking Spotify playback"
                sr_spotify_forget()
                try await NativeSpotify.connect(accessToken: saved.accessToken)
                playbackReady = true
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelSignIn() { loginTask?.cancel(); closeBrowser() }

    func checkConnection() {
        guard loginTask == nil, tokens != nil else { return }
        error = nil
        playbackReady = false
        stage = "Checking Spotify playback"
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { loginTask = nil; stage = nil }
            do {
                let token = try await accessToken()
                sr_spotify_forget()
                try await NativeSpotify.connect(accessToken: token)
                playbackReady = true
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func signOut() {
        cancelSignIn()
        sr_spotify_forget()
        tokens = nil
        playbackReady = false
        TokenStore.remove()
        error = nil
    }

    func accessToken() async throws -> String {
        guard let tokens else { throw SpotifyError.message("Sign in to Spotify before loading a Spotify link.") }
        if tokens.expiration.timeIntervalSinceNow > 60 { return tokens.accessToken }
        let (data, status) = try await Self.post("api/token", values: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": tokens.refreshToken
        ])
        guard status == 200 else { throw SpotifyError.message("Your Spotify sign-in has expired. Sign in again.") }
        let next = try Tokens(envelope: JSONDecoder().decode(TokenEnvelope.self, from: data), previous: tokens)
        try TokenStore.save(next)
        self.tokens = next
        return next.accessToken
    }

    private func poll(_ authorization: DeviceAuthorization) async throws -> TokenEnvelope {
        var interval = max(5, authorization.interval)
        let deadline = ContinuousClock.now + .seconds(min(authorization.expires_in, 600))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (data, status) = try await Self.post("api/token", values: [
                "client_id": Self.clientID,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": authorization.device_code
            ])
            let response = try JSONDecoder().decode(TokenEnvelope.self, from: data)
            if status == 200, response.access_token != nil { return response }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw SpotifyError.message("Spotify sign-in was declined.")
            case "expired_token": throw SpotifyError.message("Spotify sign-in expired. Please try again.")
            default: throw SpotifyError.message("Spotify could not finish sign-in (HTTP \(status)).")
            }
        }
        throw SpotifyError.message("Spotify did not finish sign-in within ten minutes. Please try again.")
    }

    private func openBrowser(_ url: URL) throws {
        let id = UUID()
        browserID = id
        // Device authorization completes by polling, so no callback URL is needed.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.browserID == id else { return }
                self.cancelSignIn()
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        browser = session
        guard session.start() else { throw SpotifyError.message("The Spotify sign-in browser could not open.") }
    }

    private func closeBrowser() {
        browserID = nil
        browser?.cancel()
        browser = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) ?? UIWindow()
    }

    private static func post(_ path: String, values: [String: String]) async throws -> (Data, Int) {
        var fields = URLComponents()
        fields.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.message("Spotify returned an unreadable response.") }
        return (data, http.statusCode)
    }

    private struct DeviceAuthorization: Decodable {
        let device_code: String
        let verification_uri: URL
        let verification_uri_complete: URL?
        let expires_in: Int
        let interval: Int
    }

    fileprivate struct TokenEnvelope: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let error: String?
    }

    fileprivate struct Tokens: Codable {
        let accessToken: String
        let refreshToken: String
        let expiration: Date

        init(envelope: TokenEnvelope, previous: Tokens?) throws {
            guard let access = envelope.access_token, !access.isEmpty,
                  let refresh = envelope.refresh_token ?? previous?.refreshToken, !refresh.isEmpty else {
                throw SpotifyError.message("Spotify did not return a reusable sign-in. Please try again.")
            }
            accessToken = access
            refreshToken = refresh
            expiration = Date().addingTimeInterval(envelope.expires_in ?? 3_600)
        }
    }

    private enum TokenStore {
        static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SlowroomSpotify", kSecAttrAccount as String: "tokens"]
        }
        static func load() -> Tokens? {
            var request = query
            request[kSecReturnData as String] = true
            var value: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
            return try? JSONDecoder().decode(Tokens.self, from: data)
        }
        static func save(_ tokens: Tokens) throws {
            let data = try JSONEncoder().encode(tokens)
            let attributes = [kSecValueData as String: data]
            let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if result == errSecSuccess { return }
            guard result == errSecItemNotFound else { throw SpotifyError.message("The iPhone could not save your Spotify sign-in.") }
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw SpotifyError.message("The iPhone could not save your Spotify sign-in.") }
        }
        static func remove() { SecItemDelete(query as CFDictionary) }
    }
}

enum SpotifyError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

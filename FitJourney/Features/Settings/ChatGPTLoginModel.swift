import AuthenticationServices
import Foundation
import Observation
import UIKit

/// Login da assinatura ChatGPT (experimental, não oficial) — porta de `ChatGPTLoginModel` do fireplaice.
///
/// O cliente OAuth só aceita `http://localhost:1455/auth/callback` como redirect, que a
/// `ASWebAuthenticationSession` não entrega. Então a página abre numa `ASWebAuthenticationSession` (folha no
/// app; o app fica em primeiro plano e o listener continua vivo) enquanto o `ChatGPTLoopbackListener` recebe o
/// redirect. Se a porta estiver ocupada, o usuário abre a página no Safari e cola a URL final.
@MainActor
@Observable
final class ChatGPTLoginModel {
    enum Phase: Equatable {
        case idle
        /// A página está aberta; o callback chega sozinho.
        case waiting
        /// O listener não subiu: abrir no navegador e colar a URL final.
        case manual(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var attempt: ChatGPTLoginAttempt?
    @ObservationIgnored private var listener: ChatGPTLoopbackListener?
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = LoginPresenter()
    @ObservationIgnored private let oauth: ChatGPTOAuthClient

    init(oauth: ChatGPTOAuthClient = ChatGPTOAuthClient()) {
        self.oauth = oauth
    }

    var isBusy: Bool {
        switch phase {
        case .waiting, .manual: true
        case .idle, .failed: false
        }
    }

    /// Faz o login inteiro. Devolve `true` quando os tokens já estão no Keychain.
    func signIn(store: any ChatGPTCredentialStore) async -> Bool {
        guard !isBusy else { return false }
        let attempt = oauth.beginLogin()
        self.attempt = attempt
        let listener = ChatGPTLoopbackListener()
        do {
            try await listener.start()
        } catch {
            listener.stop()
            phase = .manual(attempt.authorizeURL)
            return false
        }
        self.listener = listener
        phase = .waiting
        startWebSession(attempt.authorizeURL, listener: listener)
        let result: Bool
        do {
            let callback = try await listener.callback() // `cancel()` para o listener e encerra a espera
            webSession?.cancel()
            result = await finish(callback: callback, requireState: true, store: store)
        } catch {
            result = false
        }
        cleanup()
        return result
    }

    /// Fallback de colar: URL de callback ou só o código.
    func finishManually(_ text: String, store: any ChatGPTCredentialStore) async -> Bool {
        guard case .manual = phase else { return false }
        guard let parsed = ChatGPTOAuthClient.parseCallback(text) else {
            phase = .failed(String(localized: "Isso não parece um endereço de login. Cole a URL inteira em que o navegador parou."))
            return false
        }
        let ok = await finish(callback: .init(code: parsed.code, state: parsed.state, error: nil),
                              requireState: false, store: store)
        attempt = nil
        return ok
    }

    func cancel() {
        webSession?.cancel()
        listener?.stop()
        listener = nil
        webSession = nil
        attempt = nil
        phase = .idle
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Privado

    private func finish(callback: ChatGPTLoopbackListener.Callback, requireState: Bool,
                        store: any ChatGPTCredentialStore) async -> Bool {
        guard let attempt else { return false }
        let code: String
        do {
            code = try ChatGPTLoginValidation.code(from: callback, attempt: attempt, requireState: requireState)
        } catch {
            switch error {
            case .denied:
                phase = .failed(String(localized: "O ChatGPT não aprovou o login."))
            case .stateMismatch:
                phase = .failed(String(localized: "A resposta do login não corresponde a este pedido. Tente de novo."))
            }
            return false
        }
        do {
            let credentials = try await oauth.exchange(code: code, attempt: attempt)
            try store.save(credentials)
            phase = .idle
            return true
        } catch {
            // Só a categoria: nada do provedor é mostrado cru (e tokens nunca entram em erro).
            phase = .failed(String(localized: "Não foi possível concluir o login no ChatGPT. Tente de novo."))
            return false
        }
    }

    private func startWebSession(_ url: URL, listener: ChatGPTLoopbackListener) {
        // O esquema nunca é chamado (o redirect é http://localhost); serve só para a API.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("fitjourney-oauth")) { @Sendable _, error in
            // Chamado numa fila privada. Usuário fechou a folha: para de esperar. Depois do nosso cancel() a espera já acabou.
            if error != nil { listener.stop() }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        if !session.start() { listener.stop() }
    }

    private func cleanup() {
        listener?.stop()
        listener = nil
        webSession = nil
        attempt = nil
        if phase == .waiting { phase = .idle }
    }
}

@MainActor
private final class LoginPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first {
            return window
        }
        // Sem janela não há o que apresentar; a folha nem chega a abrir e o fluxo cai no "Cancelar".
        guard let scene = scenes.first else { preconditionFailure("sem cena para apresentar o login") }
        return ASPresentationAnchor(windowScene: scene)
    }
}

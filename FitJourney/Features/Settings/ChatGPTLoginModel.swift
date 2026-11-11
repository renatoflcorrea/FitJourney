import AuthenticationServices
import Foundation
import Observation
import UIKit

/// Login da assinatura ChatGPT (experimental, não oficial) — porta de `ChatGPTLoginModel` do fireplaice.
///
/// O cliente OAuth só aceita `http://localhost:1455/auth/callback` como redirect, que a
/// `ASWebAuthenticationSession` não entrega. Então a página abre numa `ASWebAuthenticationSession` (folha no
/// app; o app fica em primeiro plano e o listener continua vivo) enquanto o `ChatGPTLoopbackListener` recebe o
/// redirect (só com o `state` desta tentativa). Se a porta estiver ocupada (ou não houver janela para a folha),
/// o usuário abre a página no Safari e cola a URL final inteira.
@MainActor
@Observable
final class ChatGPTLoginModel {
    enum Phase: Equatable {
        case idle
        /// A página está aberta (ou abrindo); o callback chega sozinho.
        case waiting
        /// Fallback: abrir no navegador e colar a URL final. `problem` = a última colagem não serviu.
        case manual(URL, problem: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var attempt: ChatGPTLoginAttempt?
    @ObservationIgnored private var listener: ChatGPTLoopbackListener?
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private var presenter: LoginPresenter?
    /// Muda a cada tentativa e em `cancel()`: uma tentativa cancelada durante `start()` não continua.
    @ObservationIgnored private var generation = 0
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
        generation += 1
        let current = generation
        let attempt = oauth.beginLogin()
        self.attempt = attempt
        phase = .waiting // antes do await: um segundo toque não abre outra tentativa
        let listener = ChatGPTLoopbackListener(expectedState: attempt.state)
        self.listener = listener
        do {
            try await listener.start()
        } catch {
            listener.stop()
            guard generation == current else { return false }
            self.listener = nil
            phase = .manual(attempt.authorizeURL, problem: nil)
            return false
        }
        guard generation == current, !Task.isCancelled else {
            listener.stop()
            return false
        }
        guard startWebSession(attempt.authorizeURL, listener: listener) else {
            listener.stop()
            self.listener = nil
            phase = .manual(attempt.authorizeURL, problem: nil)
            return false
        }
        let result: Bool
        do {
            let callback = try await listener.callback() // timeout, `cancel()` ou fechar a folha encerram
            webSession?.cancel()
            result = generation == current ? await finish(callback: callback, store: store) : false
        } catch {
            result = false
        }
        if generation == current { cleanup() }
        return result
    }

    /// Fallback de colar: a URL de callback inteira (com `state`).
    func finishManually(_ text: String, store: any ChatGPTCredentialStore) async -> Bool {
        guard case let .manual(url, _) = phase else { return false }
        guard let callback = ChatGPTOAuthClient.parseCallback(text) else {
            phase = .manual(url, problem: String(localized: "Isso não parece o endereço de retorno do login. Cole a URL inteira em que o navegador parou (começa com http://localhost:1455/auth/callback)."))
            return false
        }
        let ok = await finish(callback: callback, store: store)
        if ok {
            attempt = nil
        } else if case let .failed(message) = phase {
            phase = .manual(url, problem: message) // mantém o formulário para tentar de novo
        }
        return ok
    }

    func cancel() {
        generation += 1
        webSession?.cancel()
        listener?.stop()
        listener = nil
        webSession = nil
        presenter = nil
        attempt = nil
        phase = .idle
    }

    // MARK: - Privado

    private func finish(callback: ChatGPTLoopbackListener.Callback, store: any ChatGPTCredentialStore) async -> Bool {
        guard let attempt else { return false }
        let code: String
        do {
            code = try ChatGPTLoginValidation.code(from: callback, attempt: attempt)
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

    /// `false` se não há janela para apresentar a folha (cai no fallback manual).
    private func startWebSession(_ url: URL, listener: ChatGPTLoopbackListener) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else {
            return false
        }
        let presenter = LoginPresenter(anchor: window)
        // O esquema nunca é chamado (o redirect é http://localhost); serve só para a API.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("fitjourney-oauth")) { @Sendable _, error in
            // Chamado numa fila privada. Usuário fechou a folha: para de esperar. Depois do nosso cancel() a espera já acabou.
            if error != nil { listener.stop() }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        self.presenter = presenter
        webSession = session
        return session.start()
    }

    private func cleanup() {
        listener?.stop()
        listener = nil
        webSession = nil
        presenter = nil
        attempt = nil
        if phase == .waiting { phase = .idle }
    }
}

@MainActor
private final class LoginPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

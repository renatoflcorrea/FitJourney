import XCTest

/// Fluxo da demonstração para a App Review (proposta ai-consent-review §8, pacote P-S2): configura o OpenCode Go,
/// importa as 4 fichas em PDF escolhidas no app Arquivos, passa pela folha "Antes de enviar" e cria o programa.
/// Usa a rede e uma chave real: sem `FJ_OPENCODE_KEY` no ambiente do executor (`TEST_RUNNER_FJ_OPENCODE_KEY` no
/// xcodebuild), o teste é pulado. Gravação: `scripts/record-review-demo.sh`.
final class ReviewDemoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    /// Tempo para quem assiste ler a tela (o teste em si não precisa).
    private func pause(_ seconds: TimeInterval = 1.2) { Thread.sleep(forTimeInterval: seconds) }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    @discardableResult
    private func tap(_ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing \(id)", file: file, line: line)
        if !target.isHittable { app.swipeUp() }
        target.tap()
        return target
    }

    /// Seletor de documentos do sistema: Procurar › No meu iPhone › Selecionar › arquivos › Abrir.
    private func pickFiles(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 8) { browse.tap(); pause(0.6) }
        let onDevice = app.staticTexts["On My iPhone"].firstMatch
        if onDevice.waitForExistence(timeout: 5) { onDevice.tap(); pause(0.8) }
        let select = app.buttons["Select"].firstMatch
        if select.waitForExistence(timeout: 5) { select.tap(); pause(0.6) }
        for name in names {
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "missing file \(name)", file: file, line: line)
            item.tap()
            pause(0.5)
        }
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "missing Open", file: file, line: line)
        open.tap()
    }

    @MainActor
    func testReviewDemoFlow() throws {
        let key = ProcessInfo.processInfo.environment["FJ_OPENCODE_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "FJ_OPENCODE_KEY not set")
        app.launch()
        pause(2)

        // 1. Ajustes › Coach e IA › OpenCode Go › chave
        tap("settings.open")
        pause()
        tap("settings.ai")
        pause()
        tap("settings.ai.provider")
        pause(0.8)
        let openCode = app.buttons["OpenCode Go"].firstMatch
        XCTAssertTrue(openCode.waitForExistence(timeout: 10))
        openCode.tap()
        pause()
        let field = tap("settings.ai.key.field")
        field.typeText(key)
        pause(0.8)
        tap("settings.ai.key.save")
        // A lista de modelos da conta carrega com a chave (o padrão gpt-6-luna lê imagens).
        XCTAssertTrue(element("settings.ai.model.gpt-6-luna").waitForExistence(timeout: 30))
        pause(2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(0.8)
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown(velocity: .fast) }
        pause()

        // 2. Treinos › + › Importar com IA › PDF ou arquivo › as 4 fichas em "No meu iPhone"
        //    (o script copia os PDFs para o armazenamento local do app Arquivos do simulador).
        app.tabBars.buttons.element(boundBy: 1).tap()
        pause()
        tap("training.add")
        pause(0.8)
        tap("training.add.import")
        pause()
        tap("import.source.files")
        pickFiles(["Chest_and_Biceps_Workout", "Back_and_Triceps_Workout", "Leg_Workout", "Shoulder_Workout"])
        pause(1.5)
        tap("import.analyze")

        // 3. Antes de enviar: o que vai, para quem, Permitir
        XCTAssertTrue(element("aiConsent.title").waitForExistence(timeout: 10))
        pause(2.5)
        app.swipeUp()
        pause(2.5)
        tap("aiConsent.allow")

        // 4. Análise, dúvidas e revisão
        let review = element("import.review.create")
        let groups = element("import.groups.continue")
        let skip = element("import.interview.skip")
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !review.exists {
            if groups.exists, groups.isHittable { pause(2); groups.tap(); continue }
            if skip.exists, skip.isHittable { pause(2); skip.tap(); continue }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(review.exists, "the import did not reach the review step")
        pause(2)
        app.swipeUp()
        pause(1.5)
        app.swipeDown()
        pause(1)
        review.tap()

        // 5. Programa criado
        let finished = element("import.done")
        if finished.waitForExistence(timeout: 20) {
            pause(2)
            finished.tap()
        }
        pause(3)
    }
}

import XCTest

/// Dieta › Plano › tocar no plano: o editor abre e fica aberto; voltar retorna à lista (defeito visto no aparelho:
/// a tela abria e saía sozinha). Usa a dieta de demonstração (`-fj.seedDemo YES`), sem rede.
final class NutritionNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-fj.startTab", "nutrition"]
    }

    func testPlanEditorStaysOpen() {
        app.launch()
        let dietName = "Diet \(Int.random(in: 1000 ... 9999))"
        let menu = app.descendants(matching: .any)["nutrition.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let plans = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plans.waitForExistence(timeout: 5))
        plans.tap()

        // Cria uma dieta pela tela (sem rede).
        let create = app.navigationBars.buttons["New plan"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        create.tap()
        let newPlanItem = app.buttons["New plan"].firstMatch // item do menu
        if newPlanItem.waitForExistence(timeout: 3) { newPlanItem.tap() }
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(dietName)
        app.buttons["Save"].firstMatch.tap()
        let activate = app.buttons["Activate now"].firstMatch
        if activate.waitForExistence(timeout: 3) { activate.tap() }

        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", dietName)).firstMatch
        if !row.waitForExistence(timeout: 10) { print("TREE>>>\n\(app.debugDescription)\n<<<TREE") }
        XCTAssertTrue(row.exists, "missing plan row")
        row.tap()

        let goals = app.staticTexts["Daily goals"].firstMatch
        if !goals.waitForExistence(timeout: 5) { print("TREE2>>>\n\(app.debugDescription)\n<<<TREE2") }
        XCTAssertTrue(goals.exists, "editor did not open")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(goals.exists && goals.isHittable, "editor closed by itself")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back did not return to the plan list")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(row.isHittable, "plan list did not stay")

        // De novo: a segunda abertura também fica.
        row.tap()
        XCTAssertTrue(goals.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(goals.exists && goals.isHittable, "editor closed by itself on second open")
    }
}

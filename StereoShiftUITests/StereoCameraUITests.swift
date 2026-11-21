import XCTest

final class StereoCameraUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testGuidedPairReviewRetakeAndSBSResult() {
        let app = launchCameraFixture()
        app.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["openStereoCamera"].waitForExistence(timeout: 5))
        snapshot("01-camera-introduction")
        app.buttons["openStereoCamera"].tap()
        let shutter = app.buttons["stereoCameraShutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "Take left photo")
        snapshot("02-left-capture")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["Left photo saved"].waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "Take right photo")
        snapshot("03-right-guidance")
        shutter.tap()
        XCTAssertTrue(app.buttons["createCameraSBS"].waitForExistence(timeout: 5))
        snapshot("04-pair-review")
        app.buttons["Retake right"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "Take right photo")
        shutter.tap()
        app.buttons["createCameraSBS"].tap()
        XCTAssertTrue(app.staticTexts["Stereo photo ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Save to In-App Gallery"].exists)
        snapshot("05-sbs-result")
    }

    @MainActor
    func testLandscapeAndDiscardConfirmation() {
        let app = launchCameraFixture()
        app.buttons["Camera"].tap()
        app.buttons["openStereoCamera"].tap()
        let shutter = app.buttons["stereoCameraShutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        snapshot("06-landscape-camera")
        XCTAssertTrue(shutter.isHittable)
        shutter.tap()
        app.buttons["Close camera"].tap()
        XCTAssertTrue(app.buttons["Discard photos"].waitForExistence(timeout: 5))
        app.buttons["Keep taking photos"].tap()
        XCTAssertTrue(shutter.exists)
        app.buttons["Close camera"].tap()
        app.buttons["Discard photos"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["openStereoCamera"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCameraControlsAtAccessibilityTextSize() {
        let app = launchCameraFixture(largeText: true)
        app.buttons["Camera"].tap()
        app.buttons["openStereoCamera"].tap()
        let shutter = app.buttons["stereoCameraShutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertEqual(shutter.label, "Take right photo")
        snapshot("07-accessibility-camera")
        shutter.tap()
        XCTAssertTrue(app.buttons["createCameraSBS"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOffTargetSecondPhotoAndDefaultOverlay() {
        let app = launchCameraFixture(offTarget: true)
        app.buttons["Camera"].tap()
        app.buttons["openStereoCamera"].tap()
        let shutter = app.buttons["stereoCameraShutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()
        let overlay = app.buttons["stereoCameraOverlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertEqual(overlay.value as? String, "On")
        overlay.tap()
        XCTAssertEqual(overlay.value as? String, "Off")
        overlay.tap()
        XCTAssertEqual(overlay.value as? String, "On")
        XCTAssertTrue(shutter.isEnabled)
        snapshot("08-off-target-overlay")
        shutter.tap()
        XCTAssertTrue(app.buttons["createCameraSBS"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLimitedTrackingDoesNotBlockSecondPhoto() {
        let app = launchCameraFixture(offTarget: true, limitedTracking: true)
        app.buttons["Camera"].tap()
        app.buttons["openStereoCamera"].tap()
        let shutter = app.buttons["stereoCameraShutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertTrue(app.staticTexts["Finding position…"].waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        XCTAssertTrue(app.buttons["createCameraSBS"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCameraLocalizationInEverySupportedLanguage() {
        let languages = [
            ("english", "Camera", "Open stereo camera", "Take left photo", "Take right photo", "Create SBS photo"),
            ("spanish", "Cámara", "Abrir cámara estéreo", "Tomar foto izquierda", "Tomar foto derecha", "Crear foto SBS"),
            ("arabic", "الكاميرا", "فتح الكاميرا المجسّمة", "التقاط الصورة اليسرى", "التقاط الصورة اليمنى", "إنشاء صورة SBS"),
            ("hindi", "कैमरा", "स्टीरियो कैमरा खोलें", "बाईं फ़ोटो लें", "दाईं फ़ोटो लें", "SBS फ़ोटो बनाएँ"),
            ("french", "Appareil photo", "Ouvrir la caméra stéréo", "Prendre la photo gauche", "Prendre la photo droite", "Créer la photo SBS"),
            ("brazilianPortuguese", "Câmera", "Abrir câmera estéreo", "Tirar foto esquerda", "Tirar foto direita", "Criar foto SBS"),
            ("simplifiedChinese", "相机", "打开立体相机", "拍摄左侧照片", "拍摄右侧照片", "生成 SBS 照片"),
            ("japanese", "カメラ", "ステレオカメラを開く", "左の写真を撮影", "右の写真を撮影", "SBS写真を作成"),
            ("korean", "카메라", "스테레오 카메라 열기", "왼쪽 사진 촬영", "오른쪽 사진 촬영", "SBS 사진 만들기")
        ]
        for (language, tab, open, left, right, create) in languages {
            // Keep iOS English to verify the in-app language preference controls the entire sheet.
            let app = launchCameraFixture(language: language)
            app.buttons[tab].tap()
            let openButton = app.buttons["openStereoCamera"]
            XCTAssertTrue(openButton.waitForExistence(timeout: 5))
            XCTAssertEqual(openButton.label, open)
            snapshot("localized-\(language)-intro")
            openButton.tap()
            let shutter = app.buttons["stereoCameraShutter"]
            XCTAssertTrue(shutter.waitForExistence(timeout: 5))
            XCTAssertEqual(shutter.label, left)
            shutter.tap()
            XCTAssertEqual(shutter.label, right)
            snapshot("localized-\(language)-right")
            XCTAssertTrue(shutter.isHittable)
            shutter.tap()
            let createButton = app.buttons["createCameraSBS"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 5))
            XCTAssertEqual(createButton.label, create)
            app.terminate()
        }
    }

    @MainActor
    private func launchCameraFixture(largeText: Bool = false, offTarget: Bool = false, limitedTracking: Bool = false, language: String = "english") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["STEREOSHIFT_CAMERA_FIXTURE"] = "1"
        app.launchEnvironment["STEREOSHIFT_CAMERA_OFF_TARGET"] = offTarget ? "1" : "0"
        app.launchEnvironment["STEREOSHIFT_CAMERA_LIMITED_TRACKING"] = limitedTracking ? "1" : "0"
        app.launchArguments += ["-appLanguage", language, "-AppleLanguages", "(en)", "-AppleLocale", "en_NZ"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

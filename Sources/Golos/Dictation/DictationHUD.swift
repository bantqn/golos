import SwiftUI
import AppKit

/// Панель диктовки, которую можно таскать по экрану.
///
/// `NSPanel` со стилем `.nonactivatingPanel`: показывается поверх всего и —
/// в отличие от обычного окна — не активирует приложение, когда её тянут или
/// щёлкают по её содержимому. Это принципиально: активируйся приложение, и
/// распознанный текст ушёл бы в него вместо того окна, где стоит курсор.
@MainActor
final class DictationHUD {

    private var panel: HUDPanel?
    private var moveObserver: NSObjectProtocol?
    private unowned let controller: DictationController
    private unowned let settings: Settings
    private unowned let models: ModelStore

    /// Размер приходит из SwiftUI: панель обтягивает содержимое, чтобы
    /// прозрачные поля не перехватывали щелчки мимо плашки.
    private var contentSize = NSSize(width: 360, height: 56)

    init(controller: DictationController, settings: Settings, models: ModelStore) {
        self.controller = controller
        self.settings = settings
        self.models = models
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        if settings.hudPositionX == nil { placeAtDefaultPosition(panel) }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        let view = DictationHUDView(
            controller: controller,
            settings: settings,
            models: models,
            onSizeChange: { [weak self] size in self?.resize(to: size) }
        )
        let hosting = TransparentHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        // Без этого вокруг плашки виден серый прямоугольник: NSHostingView
        // по умолчанию заливает свой слой непрозрачным цветом.

        let panel = HUDPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Панель должна ловить мышь — иначе её не потащить и настройки не нажать.
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel

        restorePosition(panel)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Меняет размер, оставляя левый нижний угол на месте: плашка растёт вверх,
    /// а не съезжает с того места, куда её поставили.
    private func resize(to size: NSSize) {
        guard size.width > 1, size.height > 1 else { return }
        contentSize = size
        guard let panel else { return }
        let origin = panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func placeAtDefaultPosition(_ panel: HUDPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 64))
    }

    private func restorePosition(_ panel: HUDPanel) {
        guard let x = settings.hudPositionX, let y = settings.hudPositionY else {
            placeAtDefaultPosition(panel)
            return
        }
        let point = NSPoint(x: x, y: y)
        // Экраны могли поменяться — проверяем, что точка ещё на каком-то из них.
        let visible = NSScreen.screens.contains { $0.frame.contains(point) }
        if visible {
            panel.setFrameOrigin(point)
        } else {
            placeAtDefaultPosition(panel)
        }
    }

    private func savePosition() {
        guard let panel else { return }
        settings.hudPositionX = panel.frame.origin.x
        settings.hudPositionY = panel.frame.origin.y
    }

    /// Сбрасывает плашку на место по умолчанию.
    func resetPosition() {
        settings.hudPositionX = nil
        settings.hudPositionY = nil
        if let panel { placeAtDefaultPosition(panel) }
    }

    /// Пока настройки раскрыты, панели разрешено становиться активной:
    /// без этого выпадающие меню внутри неё не открываются.
    func setAcceptsKey(_ accepts: Bool) {
        panel?.allowsKey = accepts
        if accepts { panel?.makeKeyAndOrderFront(nil) }
    }
}

/// `NSHostingView` иногда рисует фон окна до первого SwiftUI-кадра, даже если
/// его layer уже прозрачный. Явно объявляем view прозрачным на уровне AppKit —
/// это убирает прямоугольный ореол при появлении HUD.
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTransparency()
    }

    private func configureTransparency() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

/// Панель, которая становится активной только когда это разрешено.
final class HUDPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

import Flutter
import UIKit

/// Mode Focus de Vibe Player sur iOS : maintien de l'écran allumé et suivi du
/// mode Économie d'énergie. Pendant iOS de VibePowerPlugin.java (Android) —
/// mêmes canaux, mêmes méthodes, même contrat : voir lib/vibe_power.dart.
///
///  - `setKeepScreenOn`   -> `UIApplication.shared.isIdleTimerDisabled`
///                           (équivalent iOS de FLAG_KEEP_SCREEN_ON) ;
///  - `isPowerSaveMode`   -> `ProcessInfo.isLowPowerModeEnabled` ;
///  - `vibe_power/power_save` -> `NSProcessInfoPowerStateDidChange`.
public class VibePowerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  // Dernier état demandé par Dart, réappliqué à chaque retour au premier plan
  // (comme Android le réapplique à chaque (re)liaison à une activité).
  private var keepScreenOn = false
  private var eventSink: FlutterEventSink?
  private var powerStateObserver: NSObjectProtocol?
  private var didBecomeActiveObserver: NSObjectProtocol?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VibePowerPlugin()

    let methods = FlutterMethodChannel(name: "vibe_power/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)

    let powerSaveEvents = FlutterEventChannel(name: "vibe_power/power_save", binaryMessenger: registrar.messenger())
    powerSaveEvents.setStreamHandler(instance)

    // Publié pour recevoir `detachFromEngine(for:)` à la destruction du moteur.
    registrar.publish(instance)
  }

  override init() {
    super.init()
    // Certains composants système (lecteurs vidéo plein écran, sélecteurs)
    // peuvent réarmer la mise en veille automatique : réapplique la demande
    // du Focus à chaque retour au premier plan. Uniquement si ce moteur l'a
    // demandée — un moteur secondaire (tâche d'arrière-plan workmanager, qui
    // enregistre aussi ce plugin) ne doit jamais écraser l'état du moteur
    // principal en forçant `false`.
    didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.keepScreenOn else { return }
      self.applyKeepScreenOn()
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setKeepScreenOn":
      keepScreenOn = (call.arguments as? Bool) ?? false
      applyKeepScreenOn()
      result(nil)
    case "isPowerSaveMode":
      result(ProcessInfo.processInfo.isLowPowerModeEnabled)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - FlutterStreamHandler (bascules du mode Économie d'énergie)

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stopListening()
    eventSink = events
    // Notification postée sur un thread quelconque : `queue: .main` garantit
    // que l'EventSink Flutter n'est appelé que depuis le thread principal.
    powerStateObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name.NSProcessInfoPowerStateDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.eventSink?(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopListening()
    return nil
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    stopListening()
    if let observer = didBecomeActiveObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    didBecomeActiveObserver = nil
    // Ne rend la main au système que si CE moteur avait retenu l'écran.
    if keepScreenOn {
      keepScreenOn = false
      applyKeepScreenOn()
    }
  }

  // MARK: - Privé

  private func stopListening() {
    if let observer = powerStateObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    powerStateObserver = nil
    eventSink = nil
  }

  private func applyKeepScreenOn() {
    let enabled = keepScreenOn
    if Thread.isMainThread {
      UIApplication.shared.isIdleTimerDisabled = enabled
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = enabled
      }
    }
  }
}

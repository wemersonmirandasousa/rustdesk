import UIKit
import Flutter
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    dummyMethodToEnforceBundling();
    // DABLIU-DESK: segue vivo em segundo plano ate o usuario fechar o app
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.manterVivo(true) }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.manterVivo(false) }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
    
  // Toca silencio em loop: com UIBackgroundModes=audio o iOS nao suspende o
  // app, entao a conexao com o outro aparelho continua de pe.
  private var silencio: AVAudioPlayer?

  private func manterVivo(_ ligar: Bool) {
    if !ligar {
      silencio?.stop()
      silencio = nil
      return
    }
    if silencio != nil { return }
    do {
      let sessao = AVAudioSession.sharedInstance()
      try sessao.setCategory(.playback, options: [.mixWithOthers])
      try sessao.setActive(true)
      let player = try AVAudioPlayer(data: AppDelegate.wavSilencioso())
      player.numberOfLoops = -1
      player.volume = 0.01
      player.play()
      silencio = player
    } catch {
      NSLog("DABLIU-DESK manterVivo: \(error)")
    }
  }

  // 1 segundo de silencio: WAV PCM 8 kHz, 8 bits, mono (128 = silencio)
  private static func wavSilencioso() -> Data {
    let amostras = 8000
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + amostras))
    d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
    u32(8000); u32(8000); u16(1); u16(8)
    d.append("data".data(using: .ascii)!); u32(UInt32(amostras))
    d.append(Data(repeating: 128, count: amostras))
    return d
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}

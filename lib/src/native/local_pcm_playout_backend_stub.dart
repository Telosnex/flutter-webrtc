class BrowserPcmPlayout {
  Future<void> stop() async {}
  static bool get isSupported => false;
  Future<dynamic> invoke(String method, [dynamic args]) =>
      throw UnsupportedError('Browser only');
  static Future<void> selectAudioOutput(String deviceId) =>
      throw UnsupportedError('Browser only');
}

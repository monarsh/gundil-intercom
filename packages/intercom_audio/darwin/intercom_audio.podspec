# iOS and macOS build of the native audio library (miniaudio, Core Audio).
# The C sources are shared with Linux, Windows and Android (../src).
Pod::Spec.new do |s|
  s.name             = 'intercom_audio'
  s.version          = '1.0.0'
  s.summary          = 'Low-latency 16-bit mono PCM capture/playback (miniaudio).'
  s.homepage         = 'https://github.com/monarsh/p2p-intercom'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Gundil Intercom' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = []
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.ios.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreAudio'
  s.osx.frameworks = 'AudioToolbox', 'CoreAudio', 'AudioUnit'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/../src"',
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES',
  }
  s.swift_version = '5.0'
end

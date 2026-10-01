#
# Plugin local de Vibe Player — implémentation iOS (Swift) du mode Focus.
# Intégration CocoaPods ; l'intégration Swift Package Manager utilise
# vibe_power/Package.swift (mêmes sources). Voir lib/vibe_power.dart.
#
Pod::Spec.new do |s|
  s.name             = 'vibe_power'
  s.version          = '1.0.0'
  s.summary          = 'Mode Focus de Vibe Player : écran maintenu allumé et mode Économie d\'énergie.'
  s.description      = <<-DESC
Maintien de l'écran allumé (UIApplication.isIdleTimerDisabled) et suivi du
mode Économie d'énergie (ProcessInfo.isLowPowerModeEnabled) pour le mode Focus.
                       DESC
  s.homepage         = 'https://example.com/vibe_power'
  s.license          = { :type => 'Proprietary', :text => 'Plugin local de Vibe Player, non publié.' }
  s.author           = { 'Vibe Player' => 'vibe_power@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'vibe_power/Sources/vibe_power/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Aucune "required reason API" utilisée (isIdleTimerDisabled,
  # isLowPowerModeEnabled n'en sont pas) : manifeste de confidentialité vide,
  # fourni pour la conformité App Store.
  s.resource_bundles = {'vibe_power_privacy' => ['vibe_power/Sources/vibe_power/PrivacyInfo.xcprivacy']}
end

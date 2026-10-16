#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint lander_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'lander_flutter'
  s.version          = '0.2.0'
  s.summary          = 'Deep linking without the fuss: receive, resolve and create Lander links in Flutter apps.'
  s.description      = <<-DESC
Deep linking without the fuss: receive, resolve and create Lander links in Flutter apps.
                       DESC
  s.homepage         = 'https://golander.link'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Lander' => 'sdk@golander.link' }
  s.source           = { :path => '.' }
  s.source_files = 'lander_flutter/Sources/lander_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'lander_flutter_privacy' => ['lander_flutter/Sources/lander_flutter/PrivacyInfo.xcprivacy']}
end

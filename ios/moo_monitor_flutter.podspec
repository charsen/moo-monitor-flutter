Pod::Spec.new do |s|
  s.name             = 'moo_monitor_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Native crash bridge for moo_monitor_flutter.'
  s.description      = 'Forwards native crashes to the Dart SDK via a method channel.'
  s.homepage         = 'https://github.com/charsen/moo-monitor-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'charsen' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.swift_version = '5.0'
end

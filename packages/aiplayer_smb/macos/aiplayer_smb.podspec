Pod::Spec.new do |s|
  s.name = 'aiplayer_smb'
  s.version = '0.1.0'
  s.summary = 'Read-only SMB2/3 access for AIPlayer'
  s.homepage = 'https://github.com/sahlberg/libsmb2'
  s.license = { :type => 'LGPL-2.1-or-later', :file => '../src/vendor/libsmb2/COPYING' }
  s.author = { 'AIPlayer' => 'aiplayer@localhost' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.c'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) HAVE_CONFIG_H=1',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/../src/apple" "$(PODS_TARGET_SRCROOT)/../src/vendor/libsmb2/include" "$(PODS_TARGET_SRCROOT)/../src/vendor/libsmb2/include/smb2"',
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_ap_connect -Wl,-u,_ap_connect_checked -Wl,-u,_ap_connect_options -Wl,-u,_ap_dialect -Wl,-u,_ap_shares -Wl,-u,_ap_free_shares -Wl,-u,_ap_last_error -Wl,-u,_ap_disconnect -Wl,-u,_ap_stat -Wl,-u,_ap_opendir -Wl,-u,_ap_next -Wl,-u,_ap_closedir -Wl,-u,_ap_open -Wl,-u,_ap_read -Wl,-u,_ap_close',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO'
  }
end

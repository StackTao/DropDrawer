Pod::Spec.new do |s|
  s.name             = 'DropDrawerP2P'
  s.version          = '0.1.0'
  s.summary          = 'Prebuilt Rust iroh QUIC P2P engine XCFramework for DropDrawer iOS.'
  s.homepage         = 'https://github.com/StackTao/DropDrawer'
  s.license          = { :type => 'MIT' }
  s.author           = { 'DropDrawer' => 'dev@dropdrawer.local' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.vendored_frameworks = 'Frameworks/DropDrawerP2P.xcframework'
  s.libraries        = 'c++', 'resolv'
  s.frameworks       = 'Security', 'SystemConfiguration', 'CoreFoundation'
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) ' \
      '-Wl,-u,_dropdrawer_p2p_start ' \
      '-Wl,-u,_dropdrawer_p2p_node_info ' \
      '-Wl,-u,_dropdrawer_p2p_register_file ' \
      '-Wl,-u,_dropdrawer_p2p_authorize_token ' \
      '-Wl,-u,_dropdrawer_p2p_unregister_file ' \
      '-Wl,-u,_dropdrawer_p2p_download_file ' \
      '-Wl,-u,_dropdrawer_p2p_cancel_transfer ' \
      '-Wl,-u,_dropdrawer_p2p_poll_events ' \
      '-Wl,-u,_dropdrawer_p2p_shutdown ' \
      '-Wl,-u,_dropdrawer_p2p_free_string'
  }
end

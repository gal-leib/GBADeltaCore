Pod::Spec.new do |spec|
  spec.name         = "GBADeltaCore"
  spec.version      = "0.2"
  spec.summary      = "Game Boy Advance (mGBA) core plug-in for Delta emulator."
  spec.description  = "iOS framework that wraps mGBA to allow playing Game Boy Advance games with Delta emulator."
  spec.homepage     = "https://github.com/gal-leib/GBADeltaCore"
  spec.platform     = :ios, "14.0"
  spec.source       = { :git => "https://github.com/gal-leib/GBADeltaCore.git" }

  spec.author             = { "Riley Testut" => "riley@rileytestut.com", "Gal Leib" => "gal@leib.dev" }
  
  spec.source_files  = "GBADeltaCore/**/*.{h,m,swift}", "mgba/include/**/*.h", "mgba/src/**/*.{h,c}"
  spec.public_header_files = "GBADeltaCore/Types/GBATypes.h", "GBADeltaCore/Bridge/GBAEmulatorBridge.h", "GBADeltaCore/GBADeltaCore.h"
  spec.header_mappings_dir = ""
  spec.resource_bundles = {
    "GBADeltaCore" => ["GBADeltaCore/**/*.deltamapping", "GBADeltaCore/**/*.deltaskin"]
  }
  
  spec.dependency 'DeltaCore'
  spec.libraries = "z"
  
  spec.xcconfig = {
    "HEADER_SEARCH_PATHS" => '"${PODS_CONFIGURATION_BUILD_DIR}" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/mgba/include" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/mgba/src" "$(PODS_ROOT)/Headers/Private/GBADeltaCore/mgba/src/third-party/inih"',
    "GCC_PREPROCESSOR_DEFINITIONS" => 'STATIC_LIBRARY=1 M_CORE_GBA ENABLE_VFS ENABLE_VFS_FILE ENABLE_VFS_FD ENABLE_DIRECTORIES USE_PTHREADS HAVE_LOCALE HAVE_LOCALTIME_R HAVE_STRDUP HAVE_STRLCPY HAVE_STRTOF_L HAVE_XLOCALE'
  }
  
end

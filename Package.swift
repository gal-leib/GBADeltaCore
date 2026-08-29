// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "GBADeltaCore",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "GBADeltaCore",
            targets: ["GBADeltaCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/rileytestut/DeltaCore.git", .branch("main"))
    ],
    targets: [
        .target(
            name: "GBADeltaCore",
            dependencies: ["DeltaCore", "mGBACore", "GBABridge"],
            path: "GBADeltaCore",
            exclude: [
                "Info.plist",
                "Bridge",
                "Types",
                "Controller Skin/info.json",
                "Controller Skin/iphone_a.pdf",
                "Controller Skin/iphone_b.pdf",
                "Controller Skin/iphone_l.pdf",
                "Controller Skin/iphone_r.pdf",
                "Controller Skin/iphone_start_select.pdf",
                "Controller Skin/iphone_dpad.pdf",
                "Controller Skin/iphone_menu.pdf",
                "Controller Skin/iphone_portrait.pdf",
                "Controller Skin/iphone_landscape.pdf",
                "Controller Skin/iphone_edgetoedge_portrait.pdf",
                "Controller Skin/iphone_edgetoedge_landscape.pdf",
                "Controller Skin/ipad_portrait.pdf",
                "Controller Skin/ipad_landscape.pdf",
                "Controller Skin/ipad_landscape_splitview.pdf",
            ],
            resources: [
                .copy("Controller Skin/Standard.deltaskin"),
                .copy("Standard.deltamapping"),
            ]
        ),
        .target(
            name: "GBABridge",
            dependencies: ["DeltaCore", "mGBACore"],
            path: "GBADeltaCore",
            sources: [
                "Bridge/GBAEmulatorBridge.m",
                "Types/GBATypes.m"
            ],
            publicHeadersPath: "Bridge",
            cSettings: [
                .headerSearchPath("../mgba/include"),
                .headerSearchPath("../mgba/src"),
                .headerSearchPath("../mgba/src/third-party/inih"),
                .headerSearchPath("Types"),
                .headerSearchPath("Bridge"),
                .define("M_CORE_GBA"),
                .define("ENABLE_VFS"),
                .define("ENABLE_VFS_FILE"),
                .define("ENABLE_VFS_FD"),
                .define("ENABLE_DIRECTORIES"),
                .define("USE_PTHREADS"),
                .define("HAVE_LOCALE"),
                .define("HAVE_LOCALTIME_R"),
                .define("HAVE_STRDUP"),
                .define("HAVE_STRLCPY"),
                .define("HAVE_STRTOF_L"),
                .define("HAVE_XLOCALE"),
            ]
        ),
        .target(
            name: "mGBACore",
            path: "mgba",
            sources: [
                "src/arm",
                "src/core",
                "src/feature",
                "src/gba",
                "src/gb/audio.c",
                "src/util",
                "src/third-party/inih/ini.c",
            ],
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("src/third-party/inih"),
                .define("M_CORE_GBA"),
                .define("ENABLE_VFS"),
                .define("ENABLE_VFS_FILE"),
                .define("ENABLE_VFS_FD"),
                .define("ENABLE_DIRECTORIES"),
                .define("USE_PTHREADS"),
                .define("HAVE_LOCALE"),
                .define("HAVE_LOCALTIME_R"),
                .define("HAVE_STRDUP"),
                .define("HAVE_STRLCPY"),
                .define("HAVE_STRTOF_L"),
                .define("HAVE_XLOCALE"),
            ]
        )
    ]
)

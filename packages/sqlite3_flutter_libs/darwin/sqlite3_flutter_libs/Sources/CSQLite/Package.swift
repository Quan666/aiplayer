// swift-tools-version: 5.9
import PackageDescription

let sqliteFlags: [CSetting] = [
    .define("SQLITE_THREADSAFE", to: "1"),
    .define("SQLITE_ENABLE_DBSTAT_VTAB"), .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_RTREE"), .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
    .define("SQLITE_ENABLE_COLUMN_METADATA"), .define("SQLITE_DQS", to: "0"),
    .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"), .define("SQLITE_TEMP_STORE", to: "2"),
    .define("SQLITE_MAX_EXPR_DEPTH", to: "0"), .define("SQLITE_STRICT_SUBTYPE", to: "1"),
    .define("SQLITE_OMIT_AUTHORIZATION"),
    .define("SQLITE_OMIT_DEPRECATED"), .define("SQLITE_OMIT_PROGRESS_CALLBACK"),
    .define("SQLITE_OMIT_SHARED_CACHE"), .define("SQLITE_OMIT_TCL_VARIABLE"),
    .define("SQLITE_OMIT_TRACE"), .define("SQLITE_USE_ALLOCA"),
    .define("SQLITE_ENABLE_SESSION"), .define("SQLITE_ENABLE_PREUPDATE_HOOK"),
    .define("SQLITE_UNTESTABLE"), .define("SQLITE_HAVE_ISNAN"),
    .define("SQLITE_HAVE_LOCALTIME_R"), .define("SQLITE_HAVE_LOCALTIME_S"),
    .define("SQLITE_HAVE_MALLOC_USABLE_SIZE"), .define("SQLITE_HAVE_STRCHRNUL"),
    .unsafeFlags(["-Wno-ambiguous-macro"])
]

let package = Package(
    name: "CSQLite",
    products: [.library(name: "CSQLite", type: .dynamic, targets: ["CSQLite"])],
    targets: [
        .target(name: "CSQLite", path: ".", sources: ["sqlite3.c"],
                publicHeadersPath: "include", cSettings: sqliteFlags,
                linkerSettings: [.linkedLibrary("m")])
    ],
    cLanguageStandard: .gnu11
)

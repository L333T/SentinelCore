//! Build script for detour-sys.
//!
//! This script:
//! 1. Compiles the Detour C++ library and our C wrapper
//! 2. Generates Rust FFI bindings using bindgen

use std::env;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());

    // Paths to Detour source
    let detour_include = manifest_dir.join("recastnavigation/Detour/Include");
    let detour_source = manifest_dir.join("recastnavigation/Detour/Source");

    // Tell cargo to rerun if these files change.
    // NOTE: Watch individual source files, not directories — cargo only detects
    // directory-level structural changes (add/remove), not content modifications.
    println!("cargo:rerun-if-changed=wrapper.h");
    println!("cargo:rerun-if-changed=wrapper.cpp");
    for entry in std::fs::read_dir(&detour_source).expect("Failed to read Detour/Source") {
        let path = entry.expect("Failed to read dir entry").path();
        if path.extension().map_or(false, |ext| ext == "cpp" || ext == "h") {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
    for entry in std::fs::read_dir(&detour_include).expect("Failed to read Detour/Include") {
        let path = entry.expect("Failed to read dir entry").path();
        if path.extension().map_or(false, |ext| ext == "h") {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }

    // ==========================================================================
    // Compile Detour C++ library + our wrapper
    // ==========================================================================

    let mut build = cc::Build::new();

    // C++ standard
    build.cpp(true);

    // Use C++17 for modern features
    if cfg!(target_os = "windows") {
        build.flag("/std:c++17");
        build.flag("/EHsc"); // Enable C++ exceptions
    } else {
        build.flag("-std=c++17");
    }

    // CRITICAL: Enable 64-bit poly refs for WoW-scale worlds
    // This must match the dtPolyRef type in wrapper.h (uint64_t)
    build.define("DT_POLYREF64", "1");

    // Include paths
    build.include(&detour_include);
    build.include(&manifest_dir); // For wrapper.h

    // Detour source files
    build.file(detour_source.join("DetourAlloc.cpp"));
    build.file(detour_source.join("DetourAssert.cpp"));
    build.file(detour_source.join("DetourCommon.cpp"));
    build.file(detour_source.join("DetourNavMesh.cpp"));
    build.file(detour_source.join("DetourNavMeshBuilder.cpp"));
    build.file(detour_source.join("DetourNavMeshQuery.cpp"));
    build.file(detour_source.join("DetourNode.cpp"));

    // Our C wrapper
    build.file(manifest_dir.join("wrapper.cpp"));

    // Compile to static library
    build.compile("detour");

    // ==========================================================================
    // Generate Rust bindings with bindgen
    // ==========================================================================

    let bindings = bindgen::Builder::default()
        // Input header
        .header(manifest_dir.join("wrapper.h").to_string_lossy())
        // Include paths for bindgen's clang
        .clang_arg(format!("-I{}", detour_include.display()))
        .clang_arg(format!("-I{}", manifest_dir.display()))
        // Enable 64-bit poly refs
        .clang_arg("-DDT_POLYREF64=1")
        // Generate bindings for these functions
        .allowlist_function("wrapper_.*")
        .allowlist_function("dtStatus.*")
        // Generate bindings for these types
        .allowlist_type("dtNavMesh")
        .allowlist_type("dtNavMeshQuery")
        .allowlist_type("dtQueryFilter")
        .allowlist_type("dtPolyRef")
        .allowlist_type("dtTileRef")
        .allowlist_type("dtStatus")
        .allowlist_type("WrapperNavMeshParams")
        .allowlist_type("RandomFunc")
        // Generate bindings for these constants
        .allowlist_var("DT_.*")
        // Treat opaque types as opaque (we don't need their internals)
        .opaque_type("dtNavMesh")
        .opaque_type("dtNavMeshQuery")
        .opaque_type("dtQueryFilter")
        // Use core instead of std for no_std compatibility
        .use_core()
        // Don't generate layout tests (they can fail across platforms)
        .layout_tests(false)
        // Generate
        .generate()
        .expect("Unable to generate bindings");

    // Write bindings to OUT_DIR
    bindings
        .write_to_file(out_dir.join("bindings.rs"))
        .expect("Couldn't write bindings!");

    // Tell cargo where to find the compiled library
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=detour");

    // Link the C++ standard library. In a build script `cfg!(target_os = ...)` reflects the HOST,
    // not the build target, so cross-compiles must consult the target env vars cargo provides.
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    match (target_os.as_str(), target_env.as_str()) {
        ("linux", _) => println!("cargo:rustc-link-lib=stdc++"),
        ("macos", _) => println!("cargo:rustc-link-lib=c++"),
        // MinGW (windows-gnu), native or cross. Prefer a STATIC libstdc++ so the produced .exe is
        // self-contained (no libstdc++-6.dll alongside it); pair with `-C link-arg=-static` to make
        // libgcc/winpthread static too. The static archive's directory is discovered from the C++
        // compiler itself (no hardcoded path), and we fall back to dynamic linking if it can't be
        // found, so this never breaks a windows-gnu build. MSVC links its C++ runtime automatically.
        ("windows", "gnu") => match mingw_static_libstdcxx_dir() {
            Some(dir) => {
                println!("cargo:rustc-link-search=native={}", dir.display());
                println!("cargo:rustc-link-lib=static=stdc++");
            }
            None => println!("cargo:rustc-link-lib=stdc++"),
        },
        _ => {}
    }
}

/// Ask the target C++ compiler where its static `libstdc++.a` lives, returning the containing
/// directory when it resolves to a real absolute path. Uses `CXX_x86_64_pc_windows_gnu` when set
/// (as cargo/cc do for cross builds), else the conventional mingw g++ name.
fn mingw_static_libstdcxx_dir() -> Option<PathBuf> {
    let cxx = env::var("CXX_x86_64_pc_windows_gnu")
        .unwrap_or_else(|_| "x86_64-w64-mingw32-g++".to_string());
    let output = std::process::Command::new(&cxx)
        .arg("-print-file-name=libstdc++.a")
        .output()
        .ok()?;
    let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    if path.is_absolute() && path.exists() {
        path.parent().map(|p| p.to_path_buf())
    } else {
        None
    }
}

fn main() {
    // Note: HarmonyOS (target_env = "ohos") is handled directly in the source
    // (every `cfg(target_env = "musl")` also matches ohos). Do NOT emit a
    // synthetic `target_env="musl"` cfg here — newer rustc rejects it.
    println!("cargo:rerun-if-changed=build.rs");
}

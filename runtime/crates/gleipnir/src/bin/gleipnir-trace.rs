//! `gleipnir-trace CMD`: run CMD with `bash -c`, its opens offered to the supervisor at `$GLEIPNIR_TRACE_SOCK` first
//! (docs/develop/sandbox.md, "Seeing the files a shell step opens"). Inside the sandbox the same wrapper is the inner
//! helper started by this name ([`gleipnir::TRACE_INSIDE`]); this binary is the stand-alone form.

fn main() {
    std::process::exit(gleipnir::trace::wrapper_main(std::env::args_os().collect()));
}

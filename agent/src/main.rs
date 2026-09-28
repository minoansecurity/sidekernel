//! PID 1 when the kernel starts it; the ctl client otherwise.

#![deny(warnings)]

mod sys;
mod contract;
mod init;
mod net;
mod vsock;
mod serve;
mod process;
mod services;
mod ctl;

use std::process::ExitCode;

fn main() -> ExitCode {
    if std::process::id() == 1 { run_as_init() } else { ctl::run() }
}

fn run_as_init() -> ExitCode {
    if let Err(error) = init::boot() {
        eprintln!("sk-agent: boot failed: {error}");
        return ExitCode::FAILURE;
    }
    init::block_sigchld();
    services::start();
    if let Err(error) = serve::run() {
        eprintln!("sk-agent: control listener failed: {error}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

<picture>
  <source media="(prefers-color-scheme: light)" srcset="assets/banner-light.svg">
  <img src="assets/banner-light.svg" alt="SideKernel: an easy-to-use microVM sandbox for AI coding agents on macOS" width="100%">
</picture>

<p align="center">
  <a href="https://sidekernel.com/sidekernel.pdf"><b>Report</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com"><b>Site</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com/essay/"><b>Note from the developer</b></a>
</p>

<p align="center">
  ⭐ If this looks useful, a star helps others find it.<br>
  📣 Know someone who might like it? Feel free to pass it along.<br>
  🤝 Questions, ideas, and PRs of any size are always welcome.
</p>


SideKernel is a usable sandbox for AI coding agents (e.g. Claude Code). "Usable" means it tries to stay out of your way and to feel as if it's not there. It has zero third-party dependencies: the host uses only Apple's frameworks and the guest agent only Rust's standard library. It is developed as a capstone project for Georgia Tech's MSc in Cybersecurity.

Beyond AI agents, SideKernel is useful for trying out software without installing it on your host (e.g. untrusted npm packages).

> [!NOTE]
> SideKernel is a research prototype until the stable release v1.0.0, not yet ready for production use. That said, it's already usable for running coding agents day to day, but use it responsibly and with the risks in mind. See the <a href="https://sidekernel.com/sidekernel.pdf"><b>Report</b></a> or <a href="https://sidekernel.com"><b>sidekernel.com</b></a>.

## Install

Tested on M1 and M4 (macOS 26.2); other Apple silicon chips should work. If you tested it and ran into any issues, please [open an issue](https://github.com/minoansecurity/sidekernel/issues).

Install with `brew` (recommended)

```sh
brew tap minoansecurity/sidekernel https://github.com/minoansecurity/sidekernel && brew trust --formula minoansecurity/sidekernel/sidekernel
brew install sidekernel
```

Install directly from source:

```sh
rustup target add aarch64-unknown-linux-musl
git clone https://github.com/minoansecurity/sidekernel
cd sidekernel
make install
```

The first run downloads a Linux kernel (from Kata Containers) and an Ubuntu base image, both pinned and checked against a SHA-256, and builds the root filesystem, so it might take a minute or two.

## Usage

**On the host** (from a project folder):

```bash
sk          # launch an ephemeral microVM, current directory mounted
sidekernel  # (alias: sk)
sclaude     # launch a sandbox and start Claude Code directly
scodex      # launch a sandbox and start Codex directly
```

Log in on the host first (`claude` / `codex login`), or set `ANTHROPIC_API_KEY` /
`OPENAI_API_KEY` on the host. The sandbox uses that login through a host proxy;
your login files, API keys, and OAuth tokens stay outside the microVM.

Coming soon: `sgemini`, `sgrok`, and more.

**Inside the sandbox:**

```bash
sk-drop <host-path>   # copy a host file into the sandbox (requires approval on the host)
sk-net off/on         # cut internet access (the Claude API stays reachable); on needs approval on the host
save                  # persist installed packages across sandboxes
fightsong             # Print's Georgia Tech's fight song on the terminal 🐝 (alias: ramblinwreck)
```

You can also **drag and drop** files directly into Claude Code.

## Limitations and Notes on Security

SideKernel is a research prototype and has limitations. The code has not had a formal security review or external audit. See [threat model](https://sidekernel.com/#threat-model) and [limitations](https://sidekernel.com/#limitations) on sidekernel.com for the details, including the risks that are accepted by design.

Found a vulnerability? Please [report it privately on GitHub](https://github.com/minoansecurity/sidekernel/security/advisories/new). Reports are welcome and taken seriously, but fixes may take a little while. The project is still small and it's just me at the moment. Contributions are welcome.

## Learn more

- [Note from the developer](https://sidekernel.com/essay/): the motivation and the honest trade-offs
- [Practicum Report](https://sidekernel.com/sidekernel.pdf): the capstone final report with design and evaluation details
- [Website](https://sidekernel.com/)


## License

SideKernel is open-source software, licensed under the [Apache License, Version 2.0](LICENSE).

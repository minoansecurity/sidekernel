<picture>
  <source media="(prefers-color-scheme: light)" srcset="assets/banner-light.svg">
  <img src="assets/banner-light.svg" alt="SideKernel: an easy-to-use microVM sandbox for AI coding agents on macOS" width="100%">
</picture>

<p align="center">
  <a href="https://sidekernel.com/sidekernel.pdf"><b>Paper</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com"><b>Site</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com/essay/"><b>Note from the developer</b></a>
</p>


SideKernel is a usable sandbox for AI coding agents (e.g. Claude Code). "Usable" means it tries stays out of your way and to feel as if its not there. It is developed as a capstone project for Georgia Tech's MSc in Cybersecurity.

Beyond AI agents, SideKernel is useful for trying out software without installing it on your host (e.g. untrusted npm packages).


> [!NOTE]
> SideKernel is still in research preview and not yet ready for production use. Use it responsibly. Please read the <a href="https://sidekernel.com/sidekernel.pdf"><b>Paper</b></a> or the <a href="https://sidekernel.com"><b>sidekernel.com</b></a> to learn more.

## Install

Tested on M1 and M4 (macOS 26.2); other Apple silicon chips should work.

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

The first run builds the root filesystem so it might take a minute or two. 

## Usage

**On the host** (from a project folder):

```bash
sk          # launch an ephemeral microVM, current directory mounted
sidekernel  # (alias: sk)
sclaude     # launch a sandbox and start Claude Code directly
```

Coming soon: `scodex`, `sgemini`, `sgrok`, and more.

**Inside the sandbox:**

```bash
sk-drop <host-path>   # copy a host file into the sandbox (requires approval on the host)
sk-net on/off         # block all outbound traffic
save                  # persist installed packages across sandboxes
fightsong             # Print's Georgia Tech's fight song on the terminal 🐝 (alias: ramblinwreck)
```

You can also **drag and drop** files directly into Claude Code.

More details on SideKernel can be found on the [website](https://sidekernel.com/) and the capstone [paper](https://sidekernel.com/sidekernel.pdf)

</details>

## License

SideKernel is open-source software, licensed under the [Apache License, Version 2.0](LICENSE).

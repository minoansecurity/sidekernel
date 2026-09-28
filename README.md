<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
  <img src="assets/banner-light.svg" alt="SideKernel: an easy-to-use microVM sandbox for AI coding agents on macOS" width="100%">
</picture>

<p align="center">
  <a href="https://sidekernel.com/sidekernel.pdf"><b>Paper</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com"><b>Site</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com/essay/"><b>Note from the developer</b></a>
</p>



SideKernel is a research project, developed as a capstone for Georgia Tech's MSc in Cybersecurity, that pushes the boundaries of microVMs in the trade-off between security and usability. It's an easy-to-use isolated environment for AI coding agents, built for the everyday developer, addressing common usability barriers that typically hinder sandbox adoption. Here are a few ideas that it implements:

- The current folder is the sandbox. Changing a file in SideKernel changes it on the host and vice versa, and SideKernel has memory (e.g. of the Claude Code conversations) that happened inside this directory, inside the sandbox.
- Dropping a file from the host to the sandbox is seamless *from inside the sandbox*, with explicit host approval if not mounted. 
- Exposed sandbox ports > 1024 are automatically available on the host (unless already taken on the host).
- Has a network switch to block all internet/external traffic, while the Claude agent still works.
- Copy and paste works between the host and SideKernel's Claude sessions, for text and images: just like on the host.
- One Claude login authenticating on the Mac or inside a sandbox authenticates both.
- Claude Code feels and behaves as configured on the host (e.g. Skills, Plugins etc. are automatically transferred)

> [!NOTE]
> SideKernel is still in research preview. It is not intended for production use. Use responsibly. Please, read the <a href="https://sidekernel.com/sidekernel.pdf"><b>Paper</b></a> or the <a href="https://sidekernel.com"><b>Site</b></a> to learn more.

## Install

Requires an Apple silicon Mac on macOS 26 Tahoe (tested on M1 and M4, macOS 26.2).

```sh
brew tap minoansecurity/sidekernel https://github.com/minoansecurity/sidekernel
brew install sidekernel
```

Or from source:

```sh
rustup target add aarch64-unknown-linux-musl
git clone https://github.com/minoansecurity/sidekernel
cd sidekernel
make install
```

The first run builds the root filesystem.

## Usage

On the host, inside a project folder:

- `sk` (or `sidekernel`) launches a new ephemeral microVM, and the current directory of the host is automatically mounted.
- SideKernel also provides a faster way to start Claude: running `sclaude` directly on the host.

Inside the sandbox:

- `sk-drop <host-path>`, combined with explicit user approval outside the sandbox, drops external files into SideKernel (or drag and drop directly into Claude Code).
- `sk-net off` blocks all outbound traffic; `sk-net on` requires explicit user approval.
- With `save`, installed packages persist across sandboxes.
- `ramblinwreck` (or `fightsong`) prints the Georgia Tech fight song.

## Limitations

- The agent may read, edit or destroy anything in the mounted directory.
- A malicious agent can open ports to the host, exposing malicious services.
- Only Claude Code is integrated, other harnesses such as Codex are planned.
- The security of SideKernel is implied from an architectural perspective, but the implementation has not undergone a formal security review. It is still in research preview, and therefore not yet suitable for production deployments.
- SideKernel is not yet notarized (and it is self-signed).

The full list is in the [paper](https://sidekernel.com/sidekernel.pdf).

## License

SideKernel is open-source software, licensed under the [Apache License, Version 2.0](LICENSE).

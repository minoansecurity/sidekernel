<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
  <img src="assets/banner-light.svg" alt="SideKernel: an easy-to-use microVM sandbox for AI coding agents on macOS" width="100%">
</picture>

<p align="center">
  <a href="https://sidekernel.com/sidekernel.pdf"><b>Paper</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com"><b>Site</b></a> &nbsp;·&nbsp;
  <a href="https://sidekernel.com/essay/"><b>Note from the developer</b></a>
</p>


SideKernel is a usable sandbox for AI coding agents (e.g. Claude Code). "Usable" means it tries stays out of your way and to feel as if its not there. It is developed as a capstone project for Georgia Tech's MSc in Cybersecurity.

Beyond AI agents, SideKernel is useful for trying out software without installing it on your host (e.g. untrusted npm packages).

<details>
<summary><b>Features:</b></summary>

- The current folder is the sandbox: files sync both ways, and AI conversations persist across restarts.
- Ports opened in the sandbox are auto-forwarded to the host.
- Copy/paste of text and images works in and out of the sandbox (with most VMs it doesn't).
- The host's Claude config (skills, plugins) carries over to the sandbox.
- A network kill switch blocks all traffic when the sandbox holds sensitive data, while Claude keeps working.
- Log in to Claude once, on the host or in the sandbox, and both are authenticated.
- Non-mounted files are easy to bring in with `sk-drop <path>`, or by dragging and dropping them into Claude.
- The in-sandbox `save` command creates a personal layer that persists files, configs and installations across sandboxes.
</details>


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

<details>
<summary><b>Limitations</b></summary>

- The agent may read, edit or destroy anything in the mounted directory.
- A malicious agent can open ports to the host, exposing malicious services.
- Only Claude Code is integrated; other harnesses such as Codex are planned.
- SideKernel's security rests on its architecture, but the implementation has not had a formal security review.
- SideKernel is not yet notarized (it is self-signed).

The full list is in the [paper](https://sidekernel.com/sidekernel.pdf) and on the [website](https://sidekernel.com/).

</details>

## License

SideKernel is open-source software, licensed under the [Apache License, Version 2.0](LICENSE).

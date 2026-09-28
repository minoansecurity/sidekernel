# sha256 is set after tagging, from the value .github/workflows/release.yml prints.
class Sidekernel < Formula
  desc "Easy-to-use microVM sandbox for AI coding agents"
  homepage "https://sidekernel.com"
  url "https://github.com/minoansecurity/sidekernel/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "143817b0fee6f3708fbf4ec831f2b30adbfd88f2d72dbb75c8db33b5e3425c28"
  license "Apache-2.0"
  head "https://github.com/minoansecurity/sidekernel.git", branch: "main"

  depends_on "rustup" => :build
  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    # Same as `make stage`: the guest agent is compiled here, from this source.
    ENV["RUSTUP_HOME"] = "#{buildpath}/rustup"
    ENV["CARGO_HOME"] = "#{buildpath}/cargo"
    rustup = Formula["rustup"].opt_bin/"rustup"
    system rustup, "toolchain", "install", "stable", "--profile", "minimal",
           "--target", "aarch64-unknown-linux-musl"
    cd "agent" do
      system rustup, "run", "stable", "cargo", "build", "--release", "--locked",
             "--target", "aarch64-unknown-linux-musl"
    end

    resources_dir = buildpath/"Host/Resources"
    resources_dir.mkpath
    cp "agent/target/aarch64-unknown-linux-musl/release/sk-agent", resources_dir
    %w[save sk-drop sk-net ramblinwreck internal/seed internal/bashrc internal/clip].each do |script|
      cp "guest/#{script}", resources_dir/File.basename(script)
    end

    system "swift", "build", "-c", "release", "--disable-sandbox"
    # Ad-hoc is enough for the virtualization entitlement on the machine that installs it.
    system "codesign", "--force", "--sign", "-", "--entitlements", "sidekernel.entitlements",
           ".build/release/Host"

    # The binary picks its role from argv[0] and finds its resources beside its resolved path.
    libexec.install ".build/release/Sidekernel_Host.bundle", ".build/release/Host" => "sidekernel"
    %w[sidekernel sk sclaude].each { |name| bin.install_symlink libexec/"sidekernel" => name }
  end

  test do
    assert_match "sidekernel #{version}", shell_output("#{bin}/sidekernel --version")
  end
end

class Untofu < Formula
  desc "Supplies missing fonts to any macOS app, on demand"
  homepage "https://untofu.elusive.net"
  url "https://github.com/taggie313/untofu/releases/download/v0.3.0/untofu-0.3.0.tar.gz"
  sha256 "1f931b0b8a34a06fb6258d431810a01d09463a310eb4ada79d534a9eebb94ce0"
  license "MIT"
  head "https://github.com/taggie313/untofu.git", branch: "main"

  # Prebuilt binary, so a normal install compiles nothing and needs no
  # toolchain at all.
  #
  # Both tags point at the same file, and that is deliberate rather than a
  # mistake: the binary inside is universal (arm64 + x86_64), built with
  # `swift build --arch arm64 --arch x86_64`. One tarball genuinely runs on
  # both architectures, so an Intel bottle needs no Intel Mac to produce.
  # `any_skip_relocation` holds because the only artifact is a single
  # self-contained executable with no baked-in Cellar paths.
  #
  # Bottles are keyed to macOS version as well as architecture, so every
  # supported version is listed rather than relying on Homebrew's fallback to an
  # older tag. All ten entries are the same file.
  #
  # Claiming macOS 12 from a build made on 26 is not a guess. Package.swift
  # declares `.macOS(.v12)`, which makes the compiler reject any API newer than
  # that — so availability is checked at build time, not hoped for — and the
  # resulting binary reports `minos 12.0` on both slices.
  bottle do
    root_url "https://github.com/taggie313/untofu/releases/download/v0.3.0"
    sha256 cellar: :any_skip_relocation, arm64_monterey: "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, arm64_ventura:  "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:   "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, arm64_sequoia:  "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:    "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, monterey:       "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, ventura:        "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, sonoma:         "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, sequoia:        "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
    sha256 cellar: :any_skip_relocation, tahoe:          "abdba2f382d7156e1574a5ba343820b04e033004881d120849af6e5e2381839a"
  end

  # CoreText's font-request hook is macOS-only, and the C shim links CoreText
  # and CoreFoundation directly.
  #
  # Deliberately NO `depends_on xcode:`. That line demanded a ~15 GB Xcode
  # install from anyone building from source, and a user hit it. It was never
  # needed: the Command Line Tools ship swiftc and the macOS SDK, which is all
  # this builds against — verified by building the whole package with
  # DEVELOPER_DIR pointed at /Library/Developer/CommandLineTools. Homebrew
  # already requires the Command Line Tools to function at all, so a source
  # build now needs nothing a Homebrew user does not already have.
  #
  # Most people should not compile anything: the bottle below is a prebuilt
  # binary and needs no toolchain whatsoever.
  depends_on :macos

  def install
    # Universal, so one bottle serves both architectures. The build is a few
    # seconds either way, and it means an Intel Mac never has to be present to
    # produce something an Intel Mac can run.
    #
    # --disable-sandbox: SwiftPM wants to write its own build tree, which
    # Homebrew's build sandbox otherwise denies.
    system "swift", "build", "--disable-sandbox", "--configuration", "release",
                             "--arch", "arm64", "--arch", "x86_64"
    bin.install ".build/apple/Products/Release/untofu"
  end

  service do
    run [opt_bin/"untofu", "run"]
    keep_alive true
    log_path var/"log/untofu.log"
    error_log_path var/"log/untofu.log"
  end

  def caveats
    <<~EOS
      untofu answers font requests from other applications, so it has to be
      running to do anything. Start it with:

        brew services start untofu

      Do not also run `untofu install`. That sets up a second, competing
      agent, and two agents sharing one cache will race over it. `untofu
      install` refuses when a Homebrew-managed service is loaded, and
      `untofu status` reports both.

      A fetch is asynchronous, so the document that triggered it has already
      rendered with a substitute. Reopen it to pick the real font up.

      Adobe Acrobat resolves fonts with its own engine and never consults the
      system hook, so untofu is invisible to it. Keynote, Preview and
      PowerPoint all work.
    EOS
  end

  test do
    assert_match "untofu #{version}", shell_output("#{bin}/untofu --version")

    # `list` reads the invoking user's real cache, which may hold anything at
    # all, so assert only that it produces one of its two shapes. Asserting an
    # empty cache here fails on any machine that has actually used the tool.
    assert_match(/nothing cached|face\(s\)/, shell_output("#{bin}/untofu list"))

    # `status` exits 3 when the deprecated CoreText hook has been removed by a
    # future macOS. That is a legitimate outcome rather than a build failure, so
    # swallow the exit code and assert on the report instead.
    status = shell_output("#{bin}/untofu status || true")
    assert_match(/^hook:/, status)
  end
end

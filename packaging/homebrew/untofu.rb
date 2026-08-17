class Untofu < Formula
  desc "Supplies missing fonts to any macOS app, on demand"
  homepage "https://untofu.elusive.net"
  url "https://github.com/taggie313/untofu/releases/download/v0.2.1/untofu-0.2.1.tar.gz"
  sha256 "3196256d12cd963cde46bbcfaeab621075b9604cda9806eef5dd1bc891e14b3b"
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
  # Coverage caveat: bottles are keyed to macOS *version* as well as
  # architecture, and `tahoe` is macOS 26. Homebrew will use a bottle built on
  # an older macOS on newer systems, but never the reverse — so anyone on 15 or
  # earlier still builds from source. That is now cheap: no Xcode, just the
  # Command Line Tools, about twenty seconds.
  bottle do
    root_url "https://github.com/taggie313/untofu/releases/download/v0.2.1"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:  "9244c182a975fb9bc45d544b45d714bbc3a642f06dc1fd1053ae902a253aa240"
    sha256 cellar: :any_skip_relocation, x86_64_tahoe: "9244c182a975fb9bc45d544b45d714bbc3a642f06dc1fd1053ae902a253aa240"
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

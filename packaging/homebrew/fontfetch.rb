class Fontfetch < Formula
  desc "Supplies missing fonts to any macOS app, on demand"
  homepage "https://fontfetch.elusive.net"
  url "https://github.com/taggie313/fontfetch/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "aa2c8b7727155a3ebb307bbb6b0f0d922c6b5bbcdf03f91fe3bdc83b50efebdc"
  license "MIT"
  head "https://github.com/taggie313/fontfetch.git", branch: "main"

  # CoreText's font-request hook is macOS-only, and the C shim links CoreText
  # and CoreFoundation directly.
  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    # --disable-sandbox: SwiftPM wants to write its own build tree, which
    # Homebrew's build sandbox otherwise denies.
    system "swift", "build", "--disable-sandbox", "--configuration", "release"
    bin.install ".build/release/fontfetch"
  end

  service do
    run [opt_bin/"fontfetch", "run"]
    keep_alive true
    log_path var/"log/fontfetch.log"
    error_log_path var/"log/fontfetch.log"
  end

  def caveats
    <<~EOS
      fontfetch answers font requests from other applications, so it has to be
      running to do anything. Start it with:

        brew services start fontfetch

      Do not also run `fontfetch install`. That sets up a second, competing
      agent, and two agents sharing one cache will race over it. `fontfetch
      install` refuses when a Homebrew-managed service is loaded, and
      `fontfetch status` reports both.

      A fetch is asynchronous, so the document that triggered it has already
      rendered with a substitute. Reopen it to pick the real font up.

      Adobe Acrobat resolves fonts with its own engine and never consults the
      system hook, so fontfetch is invisible to it. Keynote, Preview and
      PowerPoint all work.
    EOS
  end

  test do
    assert_match "fontfetch #{version}", shell_output("#{bin}/fontfetch --version")

    # `list` reads the invoking user's real cache, which may hold anything at
    # all, so assert only that it produces one of its two shapes. Asserting an
    # empty cache here fails on any machine that has actually used the tool.
    assert_match(/nothing cached|face\(s\)/, shell_output("#{bin}/fontfetch list"))

    # `status` exits 3 when the deprecated CoreText hook has been removed by a
    # future macOS. That is a legitimate outcome rather than a build failure, so
    # swallow the exit code and assert on the report instead.
    status = shell_output("#{bin}/fontfetch status || true")
    assert_match(/^hook:/, status)
  end
end

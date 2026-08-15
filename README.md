# fontfetch

Supplies missing fonts to any macOS application, on demand, instead of letting it
complain.

Open a document whose fonts you don't have and macOS substitutes Helvetica and
shows you a dialog asking which replacements you'd like. fontfetch sits under
that: it answers the font request itself, fetching the font from Google Fonts and
handing it to the asking application.

```
$ fontfetch install
$ open SomeDeck.key
   ... banner: "Fetched 3 missing fonts — Karla, Rubik, and Lora"
```

It is a background launchd agent. No Dock icon, no menu-bar item, no window. It
is invisible until it has something to say.

## Install

```bash
brew tap taggie313/tap
brew trust taggie313/tap
brew install fontfetch
brew services start fontfetch
```

`brew trust` is required by Homebrew 6 for any third-party tap; the install is
refused without it.

Or from source:

```bash
swift build -c release
./.build/release/fontfetch install
```

`install` copies the binary to `~/Library/Application Support/fontfetch/bin/` and
registers a login agent, so a later `swift build --clean` or a moved checkout
won't silently break it. Use one mechanism or the other, never both — two agents
sharing one cache race over it, so `install` refuses when a Homebrew-managed
service is loaded and `fontfetch status` reports each of them.

```
fontfetch status             hook availability, agent state, cache size
fontfetch fetch <PSName>     resolve and cache one name now
fontfetch list               list cached faces
fontfetch verify             drop index entries whose file has gone missing
fontfetch uninstall          stop and remove the agent
fontfetch notify-test        post a sample banner
```

## How it works

macOS has a system-wide hook for exactly this:

```c
CFRunLoopSourceRef CTFontManagerCreateFontRequestRunLoopSource(
    CFIndex sourceOrder,
    CFArrayRef (^createMatchesCallback)(CFDictionaryRef attributes, pid_t pid));
```

Register the source on a runloop and the block fires whenever *any* process asks
CoreText for a font it cannot resolve, carrying the requested PostScript name and
the requesting PID. Whatever you return is used.

Two things about it are not in the documentation:

**The block must return an array of `CFURL`, not `CTFontDescriptor`.** The header
says only `CFArrayRef`. Returning descriptors crashes inside `libFontRegistry`:

```
-[__NSCFType baseURL]: unrecognized selector sent to instance
  ... _CFURLHasFileURLScheme
  ... XTIssueSandboxExtensionsForURLs
  ... -[TFontProviderHandler callFontProvider:]
```

**That crash also explains why this works at all.** CoreText walks the returned
URLs and issues *sandbox extensions* for each one to the requesting process. That
is what lets a sandboxed application read a font file it was never granted access
to — which is the whole ballgame, since the apps that show you this dialog are
sandboxed.

### Cache-first, always

The callback runs on the provider's runloop with the requesting application's
text layout blocked behind it. Doing a network fetch there would hang the app
mid-open. So:

- **Hit** — in-memory dictionary lookup, return the path, no dialog, no delay.
- **Miss** — return "no" immediately, then resolve, download, verify and cache on
  a background queue. The document that triggered it still renders with a
  substitute; every later open of anything using that font is a hit.

That first miss is by design and is the reason the notification says "reopen the
document".

### Resolution and verification

A PostScript name is turned into candidate family slugs — `RalewayRoman-Regular`
becomes `raleway` (the `Roman` grouping token is not part of the family name)
before `ralewayroman` — and looked up under `ofl/`, `apache/` and `ufl/` in the
[google/fonts](https://github.com/google/fonts) repository. Variable fonts are
tried first, since one `Family[wght].ttf` usually carries the entire family.

Nothing is cached until the downloaded file is parsed and proven to answer to the
exact PostScript name that was requested. This matters more than it looks:

- Google's Raleway answers to `RalewayRoman-Regular`, a name that exists only as
  a variable-font *named instance*. The file's own `name` table says
  `Raleway-Thin`. Other builds of the same family answer to `Raleway-Regular`.
  Matching on family name alone caches a file that will never satisfy the
  request, and it fails silently.
- Conversely, some variable fonts omit the optional `postScriptNameID` on their
  instances entirely — Lora does — while CoreText will still happily instantiate
  those weights from the file. So the verifier also indexes the conventional
  `Family-Style` spelling, or it would reject a file that genuinely works.

One download indexes every face it can answer to. Fetching `RalewayRoman-Regular`
indexes 18 names, including the `Raleway-*` aliases, so a document built against a
differently-named build of the same family hits the same cached file.

## Verification record

Measured on macOS 26.0 (Darwin 25.5.0), Apple Swift 6.3.3, 2026-08-14.

| Claim | Evidence |
| --- | --- |
| The hook still fires | Callback received `NSFontNameAttribute = Lora-Regular` with the requesting PID |
| It can supply an uninstalled font | `Lora-Regular` resolved from a file in `/tmp`, installed nowhere |
| Sandboxed hardened apps use it | Keynote (`flags=0x12000(library-validation,runtime)` + `com.apple.security.app-sandbox`) requested by PID and rendered the font |
| Without it, the same document substitutes | Control run with the provider stopped: `Helvetica` |

Code injection into iWork is not a viable alternative: library validation plus
hardened runtime means no `DYLD_INSERT_LIBRARIES` without disabling SIP and AMFI
machine-wide. This hook is the sanctioned path.

### Application compatibility

Each of these was tested by authoring a document against a font, removing that
font from the system, and opening the document with fontfetch running.

| Application | Consults the hook | Notes |
| --- | --- | --- |
| Keynote | yes | Rendered `Lora-Regular` with the font installed nowhere |
| Preview | yes | Non-embedded `/BaseFont /Karla-Regular` in a PDF |
| PowerPoint | yes | Asks by PostScript name even when the file says `typeface="Karla"` |
| **Adobe Acrobat** | **no** | Opened the same PDF and made no font request at all |

Acrobat is the interesting failure. It has its own font engine and multiple-master
substitution and never asks CoreText, which is presumably why Adobe built font
activation *into* their applications rather than relying on the system. fontfetch
cannot help inside Acrobat; use Adobe Fonts there.

PowerPoint is the interesting success, and it shapes two design choices. It
requests fonts as a bare family name with no style for theme fonts, so matching
only PostScript names would reject the very file that satisfies the request. And
opening any `.pptx` asks for Calibri, Aptos and Segoe UI, none of which will ever
be on Google Fonts — hence the proprietary-family list, which declines those in
about ten milliseconds with no network traffic and, importantly, without telling
the user about fonts they can do nothing about.

### Browsers get the cache read-only

Browsers reach this hook too, and fetching for them is wrong. They are declined
by default: a cache **hit** is still served, because that costs nothing and
touches no network, but a **miss** never becomes a download and never opens a
dialog. `--fetch-for-browsers` turns that off.

The mechanism is narrower than it first appears, and worth stating precisely
because the obvious guess is wrong. A plain `font-family` stack does *not* reach
this hook — that is resolved by matching against already-enumerated families.
What does reach it is:

```css
@font-face { font-family: "Product Sans"; src: local("Product Sans"), url(...); }
```

`local()` is an explicit by-name lookup, which is exactly what the hook
intercepts. It is the standard trick for "use the installed copy if the visitor
happens to have one, otherwise download it", so it is everywhere.

Measured rather than assumed: **Chromium fires the hook for `local()`;
Safari/WebKit does not.** A plain font stack fires it in neither. So on a
Chromium browser, every site offering a `local()` fallback asks the system for
that font by name — and the page renders perfectly well when the answer is no,
because the `url()` source is sitting right there.

Three reasons that matters:

- It is traffic and downloads for pages that never needed them.
- Unobtainable brand fonts pop a dialog at someone who is only browsing. Google
  properties ask for `Product Sans`, which nobody can obtain.
- Every unresolved name becomes a GitHub API call. Left unchecked, fontfetch
  quietly leaks the shape of your browsing to a third party. This is the reason
  the default is off rather than a matter of taste.

`fontfetch policy <pid>` reports how any given process would be treated.

Run the regression suite with `./scripts/selftest.sh`, or
`./scripts/selftest.sh --with-keynote` to include the full end-to-end (installs a
font, authors a deck against it, removes the font, and checks fontfetch puts it
back).

## Limitations

**The API is deprecated.** `CTFontManagerCreateFontRequestRunLoopSource` has been
marked `CT_DEPRECATED(macos(10.6, 11.0))` with "This functionality will be removed
in a future release" since macOS 11. It still works on macOS 26, fifteen releases
later, but its removal is the expected end of this tool's life. When that happens
`fontfetch run` exits with a clear message and code 3, and missing fonts behave
exactly as they did before — nothing breaks, the tool just stops helping.

**Google Fonts only.** Commercial fonts will not resolve, correctly. If you have
a licensed font, install it the normal way. When a font can't be found, fontfetch
explains why and offers somewhere to look — Adobe Fonts, MyFonts, Fontspring,
WhatTheFont — or copies the name to your clipboard. Suppress that with
`--no-dialog`.

**Not every application asks.** Adobe Acrobat resolves fonts internally and never
consults the system hook, so fontfetch is invisible to it. See the compatibility
table above.

**GitHub rate limit.** Directory listings use the unauthenticated GitHub API at 60
requests/hour. Set `GITHUB_TOKEN` to raise it. Failed names are negatively cached
for six hours so a document full of unavailable corporate fonts doesn't hammer it.

**Notifications borrow another identity.** Banners are posted via `osascript
display notification`, which attributes them to whichever bundle osascript posts
under, rather than to fontfetch. Using `UNUserNotificationCenter` instead would
require becoming a bundled, signed application — and a permanent Dock or menu-bar
presence — for something that fires a handful of times a year. If banners never
appear, check System Settings → Notifications → Script Editor. Run with `--quiet`
to disable them.

## License

MIT. See [LICENSE](LICENSE).

Fonts fetched by this tool carry their own licenses — everything under
`google/fonts` is OFL, Apache 2.0 or UFL. fontfetch downloads and caches them
for your own use; it does not redistribute them.

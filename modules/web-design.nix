# =============================================================================
# web-design.nix — Full-stack web designer/developer tooling
#
# System-level peer of modules/gaming.nix. Ships the canonical toolkit for
# designing and shipping web products:
#
#   • JS/TS runtimes & package managers (pnpm, yarn, bun, deno, …)
#   • Cloud / deploy CLIs (vercel, netlify, supabase, fly, wrangler)
#   • Local DB clients (postgres, redis, sqlite) — servers run via podman
#   • Containers (podman with docker compatibility, podman-compose, lazydocker)
#   • Image & SVG optimization (sharp/libvips, oxipng, mozjpeg, svgo, …)
#   • Browser testing rig (chromium + playwright-driver with NixOS env wiring)
#   • Design apps (inkscape, krita, figma-linux)
#   • A full system font set a web designer reaches for daily
#   • API/HTTP debugging (bruno, httpie, xh, mkcert, mitmproxy)
#   • Docs & diagrams (pandoc, typst, mermaid-cli)
#   • The expected JSON / git / data CLIs (lazygit, yq, gron, htmlq, …)
#
# Per Standard-OS rule: this is BACKGROUND INFRA. It is a tool bundle, not a
# feature — it intentionally does NOT surface in OPTIONS. Same justification
# as gaming.nix.
#
# IMPORTANT — Node.js is installed via modules/packages.nix as `pkgs.nodejs`
# (currently 22.x). DO NOT add `nodejs_22` here: two packages providing
# /bin/node would collide at activation. If we ever pin Node here, first
# remove the `nodejs` line from modules/packages.nix.
# =============================================================================
{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Web-design / web-dev system packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # --- JS/TS package managers (npm ships with nodejs) ---
    pnpm
    yarn
    bun

    # --- Alternative JS runtime ---
    deno

    # --- System TypeScript (project tsc still wins inside a repo).
    # ts-node was removed from nixpkgs — Node 22+ has built-in TS via
    # `node --experimental-strip-types` / `--experimental-transform-types`.
    typescript

    # --- Python (build scripts, image tooling, JS-tooling shims) ---
    python3
    uv

    # --- Cloud / deploy CLIs ---
    nodePackages.vercel # `vercel` CLI (note: top-level `vercel-pkg` is @vercel/pkg, a packager — not this)
    netlify-cli
    nodePackages.wrangler
    supabase-cli
    flyctl

    # --- Database CLIENTS (run servers via podman, not as host daemons) ---
    postgresql_16       # psql + libpq + server binaries (no service enabled)
    pgcli               # psql REPL with autocomplete
    sqlite
    redis               # provides redis-cli (server present but not enabled)

    # --- Container tooling (daemon enabled below via virtualisation.podman) ---
    podman-compose
    lazydocker
    dive

    # --- Image & asset optimization (covers everything sharp/squoosh does) ---
    vips                # libvips CLI (sharp's native dep)
    oxipng              # PNG recompressor
    pngquant            # PNG quantizer
    jpegoptim           # JPEG optimizer
    mozjpeg             # JPEG encoder
    libwebp             # cwebp / dwebp
    # libavif is already in modules/packages.nix (provides avifenc / avifdec)
    exiftool
    nodePackages.svgo   # SVG optimizer

    # --- Vector / raster design apps ---
    inkscape            # vector (essential for SVG work)
    krita               # digital paint (modern raster)
    figma-linux         # community Figma desktop client
    # gimp is already in modules/packages.nix

    # --- Font tooling ---
    fontforge
    woff2               # woff2_compress / woff2_decompress
    python3Packages.fonttools  # otf2ttf, pyftsubset, …

    # --- Browser testing extras (firefox + chrome already in packages.nix) ---
    chromium            # for headless / playwright
    playwright-driver   # bundles browsers + system deps (wired in env vars below)

    # --- API debugging / dev networking ---
    bruno               # FOSS API client
    httpie
    xh                  # rust port of httpie
    mkcert              # local HTTPS dev certs
    mitmproxy

    # --- Screenshot / record extras (grim/slurp/swappy already in packages.nix) ---
    satty               # modern annotator
    wf-recorder         # wayland screen-record

    # --- Docs / diagrams ---
    pandoc
    typst
    nodePackages."@mermaid-js/mermaid-cli"

    # --- Git extras (gh already in packages.nix) ---
    lazygit
    gitui
    git-lfs

    # --- Data / JSON / HTML CLIs (jq already in packages.nix) ---
    yq-go
    dasel
    gron
    htmlq

    # --- Performance audits ---
    # Lighthouse is no longer in nixpkgs as a node package and the top-level
    # `lighthouse` is Ethereum's beacon client. Run via `npx lighthouse <url>`
    # per project instead.

    # --- Editor extras (vscode, neovim already in packages.nix) ---
    helix
    micro

    # --- Code formatters / linters (project versions take over when present) ---
    nodePackages.prettier
    nodePackages.eslint
    biome

    # --- Color tools ---
    gpick               # X11 color picker (works under XWayland)

    # --- node_modules survival kit ---
    ncdu
    dust                # rust disk-usage
  ];

  # ---------------------------------------------------------------------------
  # Containers — podman, rootless, with docker CLI compatibility
  # (Daemonless model: no security or systemd surprises like dockerd brings.)
  # ---------------------------------------------------------------------------
  virtualisation.podman = {
    enable               = true;
    dockerCompat         = true;   # `docker` and `docker-compose` map to podman
    dockerSocket.enable  = true;   # /run/podman/podman.sock for compose clients
    defaultNetwork.settings.dns_enabled = true;  # name resolution between containers
  };

  # ---------------------------------------------------------------------------
  # Playwright / Puppeteer — use the nix-built browsers and skip npm's
  # downloads. Without these, `npm i playwright` pulls binaries that won't
  # exec on NixOS (dynamic-linker mismatch) and tests fail mysteriously.
  # ---------------------------------------------------------------------------
  environment.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH         = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "true";
    PUPPETEER_SKIP_DOWNLOAD          = "true";
    PUPPETEER_EXECUTABLE_PATH        = "${pkgs.chromium}/bin/chromium";
  };

  # ---------------------------------------------------------------------------
  # Fonts — what a web designer reaches for daily, installed system-wide so
  # every browser (and every design app) sees them without per-app fiddling.
  # ---------------------------------------------------------------------------
  fonts.packages = with pkgs; [
    # Google Fonts catch-all — Inter, Manrope, Work Sans, Space Grotesk,
    # Lexend, Roboto, Poppins, Plus Jakarta Sans, Bricolage Grotesque, …
    # every Google font in one package, so designers don't hit "missing
    # family" mid-comp.
    google-fonts

    # Premium non-Google families web designers reach for
    geist-font            # Vercel (sans + mono)
    jetbrains-mono
    fira-code
    iosevka
    cascadia-code
    ibm-plex              # full Plex family

    # Adobe Source families (sans/serif/code)
    source-sans
    source-serif
    source-code-pro

    # Nerd Fonts (modular access on 25.11+) — icon-bearing mockups + terminals
    nerd-fonts.fira-code
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only

    # Emoji (noto-fonts-emoji was merged into noto-fonts-color-emoji)
    noto-fonts-color-emoji
  ];
}

-- ShapeKeySystem panel: colours (ARGB) and metrics, from the UI prototype
-- (https://claude.ai/artifact/7gNPX1dR7CDeoQJtaPZNcj). One dark theme: the panel is an overlay.

local T = {}

T.c = {
    shade    = 0x66000000,
    panel    = 0xF2161C23,
    panel2   = 0xFF1D252E,
    panel3   = 0xFF26303B,
    ink      = 0xFF0F1419,
    line     = 0xFF34404C,
    text     = 0xFFE6E1D6,
    muted    = 0xFF8F9AA5,
    faint    = 0xFF5D6872,
    brass    = 0xFFD6A24A,
    brass_dim = 0xFF8A6A33,
    signal   = 0xFF58C4B0,
    signal_dim = 0xFF2B6158,
    warn     = 0xFFE0875A,
    ok       = 0xFF7FC47A,
    error    = 0xFFE05A5A,
    zone = { brow = 0xFF8FB3E0, eye = 0xFF58C4B0, nose_cheek = 0xFFE28F9A, mouth = 0xFFE0A35A },
}

T.font = {
    family = "Microsoft YaHei UI",
    mono = "Consolas",
    body = 14, small = 12, title = 16, big = 15,
}

T.m = {
    title_h = 40, rail_w = 132, status_h = 26, pad = 14, row_h = 28, gap = 8, radius = 4,
    min_w = 640, min_h = 420,
}

return T

-- suffer: the laptop. The built-in panel, plus an HDMI display when one is
-- plugged in.
--
-- Loaded by hyprland.lua when /etc/hostname matches this file's name. See
-- hosts/epiphany.lua for what belongs in one of these files and what does not.
--
-- The generated hypr/monitors.lua loads after this and wins, so what the
-- Quickshell monitor panel applies still overrides this; as of 2026-09-10 it
-- pins eDP-1 to 1920x1200@60 and HDMI-A-1 to 1920x1080@60, both at scale 1.25.
-- The blocks below are the fallback for when that file has been deleted or has
-- never been written.

hl.monitor({
    output   = "eDP-1",
    mode     = "preferred",
    position = "0x0",
    scale    = "1.5",
})

-- A rule for an output that is not plugged in is inert, so this costs nothing
-- when the laptop is on its own. position is "auto" rather than the panel's
-- measured 1536x0: that offset is the logical width of eDP-1 at scale 1.25, and
-- this file declares 1.5, so a hard coded x would leave a gap in exactly the
-- case this fallback exists for. "auto" puts it to the right of the panel,
-- which is where the panel puts it too.
hl.monitor({
    output   = "HDMI-A-1",
    mode     = "preferred",
    position = "auto",
    scale    = "1.25",
})

-- Which output carries which half of the workspaces. hyprland.lua owns the rule
-- that 1-5 go to the primary and 6-10 to the secondary; this only says which
-- physical output is which.
--
-- With HDMI-A-1 unplugged, hyprland.lua's workspace rules still name it as the
-- monitor for 6-10. Hyprland falls those back to the only live output, so the
-- laptop on its own behaves as it did when this file named no secondary.
return {
    primary   = "eDP-1",
    secondary = "HDMI-A-1",
}

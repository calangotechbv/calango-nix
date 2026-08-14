-- suffer: the laptop. One built-in panel, no external outputs declared.
--
-- Loaded by hyprland.lua when /etc/hostname matches this file's name. See
-- hosts/epiphany.lua for what belongs in one of these files and what does not.
--
-- The generated hypr/monitors.lua loads after this and wins, so what the
-- Quickshell monitor panel applies still overrides this; it currently pins
-- eDP-1 to 1920x1200@60 at scale 1.5, which is what the mode below falls back
-- to by asking for the panel's preferred mode.

hl.monitor({
    output   = "eDP-1",
    mode     = "preferred",
    position = "0x0",
    scale    = "1.5",
})

-- No secondary. With one display, hyprland.lua sends workspaces 6-10 to the
-- primary as well, rather than pinning them to an output that does not exist
-- here -- which is what the shared config used to do, stranding half the
-- workspaces on a machine that had never had a DP-1.
return {
    primary = "eDP-1",
}

-- NOT A TARGET OF THIS FLAKE. epiphany runs Fedora Linux 44 (Workstation
-- Edition), so it has no apt, no dpkg and no use for calango-desktop. Spec 18
-- named it as the worked example for a Debian 13 bootstrap before that was
-- checked; see docs/superpowers/specs/2026-08-19-bare-debian-bootstrap-design.md.
--
-- The file stays because the two-display layout below is a real measurement
-- that is expensive to recover, and because hyprland.lua's hosts/ mechanism
-- came from this machine. Do not copy it as a template for a new Debian host;
-- copy hosts/suffer.lua.

-- epiphany: the desktop. Two displays, side by side.
--
-- Loaded by hyprland.lua when /etc/hostname matches this file's name. Nothing
-- here is policy -- it is the set of facts about this machine's hardware that
-- the shared config cannot know, because that config is one file replicated to
-- every host by Syncthing.
--
-- The generated hypr/monitors.lua loads *after* this and wins, so anything the
-- Quickshell monitor panel applies still overrides these defaults; they are
-- what the machine falls back to when that file has been deleted or has never
-- been written.

hl.monitor({
    output   = "HDMI-A-1",
    mode     = "preferred",
    position = "0x0",
    scale    = "1.67",
})
hl.monitor({
    output   = "DP-1",
    mode     = "preferred",
    position = "auto",
    scale    = "1.67",
})

-- Which output carries which half of the workspaces. hyprland.lua owns the rule
-- that 1-5 go to the primary and 6-10 to the secondary; this only says which
-- physical output is which.
--
-- primary is HDMI-A-1 -- the left screen -- and naming it matters: DP-1
-- enumerates as DRM ID 0, so without a rule Hyprland would hand it workspace 1.
return {
    primary   = "HDMI-A-1",
    secondary = "DP-1",
}

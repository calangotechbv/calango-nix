pragma Singleton
import Quickshell

Singleton {
    // The scale Hyprland actually runs a mode at, given the scale asked for.
    //
    // Hyprland refuses a scale that would leave the logical size fractional and
    // substitutes the nearest multiple of 1/120 that divides both dimensions
    // evenly -- a port of CMonitor::applyMonitorRule, src/helpers/Monitor.cpp
    // lines 1034-1088 at v0.55.4, including its exact floating-point comparison,
    // so this agrees with the compositor bit for bit rather than approximately.
    //
    // It matters twice over, because hyprctl then prints the substituted scale
    // with two decimals: a 3840x2160 display at 1.67 really runs at 200/120, is
    // 2304 logical pixels wide, and `hyprctl -j monitors` says 1.67. Dividing by
    // the printed value gives 2299.4 -- a tile 4.6 px too narrow, a snap that
    // lands on a fractional edge, and a rounded position that overlaps its
    // neighbour by 0.4 px, which is what kept Apply disabled for two touching
    // displays. Feeding the printed value back through here recovers 200/120.
    //
    // Where Hyprland finds no clean divisor it falls back to a default scale this
    // side cannot know; the requested scale is returned, and the tile is merely
    // approximate in a case Hyprland reports as an error anyway.
    function effectiveScale(w, h, scale) {
        if (Number.isInteger(w / scale) && Number.isInteger(h / scale)) return scale;

        const search = Math.round(scale * 120);
        const zero   = search / 120;
        if (Number.isInteger(w / zero) && Number.isInteger(h / zero)) return zero;

        for (let i = 1; i < 90; i++) {
            const up   = (search + i) / 120;
            const down = (search - i) / 120;
            if (Number.isInteger(w / up)   && Number.isInteger(h / up))   return up;
            if (Number.isInteger(w / down) && Number.isInteger(h / down)) return down;
        }
        return scale;
    }

    // Logical (scaled, rotation-aware) width of a monitor
    function logicalW(m) {
        const s = effectiveScale(m.width, m.height, m.scale);
        return (m.transform % 2 === 0) ? m.width / s : m.height / s;
    }

    // Logical (scaled, rotation-aware) height of a monitor
    function logicalH(m) {
        const s = effectiveScale(m.width, m.height, m.scale);
        return (m.transform % 2 === 0) ? m.height / s : m.width / s;
    }

    // Parse a mode string like "1920x1080@60.00Hz"
    // Returns { w, h, rate } or null if the string doesn't match
    function parseMode(modeStr) {
        const match = modeStr.match(/^(\d+)x(\d+)@([\d.]+)Hz$/);
        if (!match) return null;
        return { w: parseInt(match[1]), h: parseInt(match[2]), rate: match[3] };
    }

    // Axis-aligned bounding-box overlap test for two rectangles
    function overlapsAABB(ax, ay, aw, ah, bx, by, bw, bh) {
        return ax < bx + bw && ax + aw > bx &&
               ay < by + bh && ay + ah > by;
    }

    // True when two rectangles share a stretch of edge -- the only arrangement
    // the pointer can cross. A corner is not enough, and neither is a gap of any
    // width: Hyprland clamps a pointer that leaves every monitor back to the
    // nearest one (CPointerManager::closestValid, v0.55.4), so only a single
    // motion event longer than the gap can land on the far side of it.
    function touchesAABB(ax, ay, aw, ah, bx, by, bw, bh) {
        const spanX = Math.min(ax + aw, bx + bw) - Math.max(ax, bx);
        const spanY = Math.min(ay + ah, by + bh) - Math.max(ay, by);
        const sideBySide = (ax + aw === bx || bx + bw === ax) && spanY > 0;
        const stacked    = (ay + ah === by || by + bh === ay) && spanX > 0;
        return sideBySide || stacked;
    }
}

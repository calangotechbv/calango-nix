#!/usr/bin/env python3
"""discover the browsers and profiles that can open a url, as json.

the picker in quickshell/browser/ runs this and parses stdout. it is a separate
script rather than qml because the work is file-format archaeology -- chrome's
Local State, firefox's profiles.ini, desktop-entry Exec lines -- and python has
a json and an ini parser in its standard library where qml has neither.

  python3 discover.py                 print the entry list as json
  python3 discover.py --fallback URL  launch the configured fallback with URL
  python3 discover.py --check         run the self-check, non-zero if it failed
"""

import sys
import configparser
import json
import os
import re
import shlex
import subprocess
import tempfile

# executable basename -> (config subdir under ~/.config, family token for ids)
#
# this table is why one browser registered under two desktop ids produces one
# set of entries: both com.google.Chrome.desktop and google-chrome.desktop
# carry Exec=/usr/bin/google-chrome-stable, and both land on "google-chrome"
# here, so the second one's entries collide with the first's and are dropped.
# lifted from browser-selector-vala's profiles.vala:51-81.
CHROMIUM_FAMILIES = {
    "google-chrome":          ("google-chrome", "chrome"),
    "google-chrome-stable":   ("google-chrome", "chrome"),
    "google-chrome-beta":     ("google-chrome-beta", "chrome-beta"),
    "google-chrome-unstable": ("google-chrome-unstable", "chrome-dev"),
    "chromium":               ("chromium", "chromium"),
    "chromium-browser":       ("chromium", "chromium"),
    "brave-browser":          ("BraveSoftware/Brave-Browser", "brave"),
    "brave":                  ("BraveSoftware/Brave-Browser", "brave"),
    "microsoft-edge":         ("microsoft-edge", "edge"),
    "microsoft-edge-stable":  ("microsoft-edge", "edge"),
    "microsoft-edge-beta":    ("microsoft-edge-beta", "edge-beta"),
    "microsoft-edge-dev":     ("microsoft-edge-dev", "edge-dev"),
    "vivaldi":                ("vivaldi", "vivaldi"),
    "vivaldi-stable":         ("vivaldi", "vivaldi"),
}

# a desktop-entry field code is a percent and exactly one letter. anything else
# beginning with a percent is an ordinary argument and stays.
_FIELD_CODE = re.compile(r"%[a-zA-Z]\Z")


def strip_field_codes(argv):
    return [a for a in argv if not _FIELD_CODE.match(a)]


def chrome_profiles(state):
    """[(profile_dir, display_name, email)] from a parsed Local State."""
    # a Local State that parsed but is not a dict (corrupt file, wrong file)
    # is "no profiles", not a crash -- state is untrusted filesystem content,
    # and every caller reaches it through here, fixture or real file alike.
    if not isinstance(state, dict):
        return []
    profile = state.get("profile") or {}
    cache = profile.get("info_cache") or {}

    # profiles_order is chrome's own ordering and is authoritative where it
    # agrees with info_cache. entries naming a directory info_cache does not
    # know are stale and dropped; entries info_cache has that the order does
    # not are new and appended.
    order = [d for d in (profile.get("profiles_order") or []) if d in cache]
    order += [d for d in cache if d not in order]

    out = []
    for directory in order:
        info = cache.get(directory) or {}
        out.append((directory,
                    info.get("name") or directory,
                    info.get("user_name") or ""))
    return out


def firefox_profiles(ini_text):
    """[(path, name)] from a profiles.ini body.

    keyed on Path rather than Name: Name is what the user types into firefox's
    profile manager and can be changed at any time, and vala keys on it
    (profiles.vala:114), so renaming a profile there silently breaks every rule
    and speed key pointing at it. Path is assigned by firefox and does not move.
    """
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        parser.read_string(ini_text)
    except configparser.Error:
        return []

    out = []
    for section in parser.sections():
        # "Install4F96D1932A9F858E" also exists in this file and is not a
        # profile, so this matches "profile" followed by digits rather than a
        # bare prefix.
        if not re.match(r"profile\d+\Z", section, re.IGNORECASE):
            continue
        path = parser[section].get("Path", "")
        if not path:
            continue
        out.append((path, parser[section].get("Name") or path))
    return out

CONFIG_PATH = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "quickshell", "browser.json")

# our own handler, skipped so the picker cannot offer to open a url with
# itself. browser-selector-vala's ids are here too: it may still be installed
# and registered while this is being rolled out.
SELF_IDS = {
    "eu.calangotech.CalangoOpen.desktop",
    "eu.calangotech.BrowserSelectorVala.desktop",
    "eu.calangotech.BrowserSelector.desktop",
    "browser-selector.desktop",
    "browser-selector-vala.desktop",
}


def data_dirs():
    home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    return [home] + [d for d in dirs.split(":") if d]


def registered_handlers():
    """desktop ids registered for https, in gio's order.

    `gio mime` prints an unindented "Default application for ..." line and then
    indented lists under "Registered applications:" and "Recommended
    applications:". taking every indented line that ends in .desktop covers
    both lists without parsing the headings, and dedup keeps gio's ordering.
    """
    try:
        out = subprocess.run(["gio", "mime", "x-scheme-handler/https"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    seen, ids = set(), []
    for line in out.splitlines():
        if not line[:1].isspace():
            continue
        entry = line.strip()
        if entry.endswith(".desktop") and entry not in seen:
            seen.add(entry)
            ids.append(entry)
    return ids


def read_desktop(desktop_id):
    """{"name", "icon", "argv"} for a desktop id, or None if unreadable."""
    for directory in data_dirs():
        path = os.path.join(directory, "applications", desktop_id)
        if not os.path.isfile(path):
            continue
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        # interpolation=None matters: Exec lines are full of percent signs and
        # configparser's default reading would choke on them.
        try:
            parser.read(path, encoding="utf-8")
            section = parser["Desktop Entry"]
        except (configparser.Error, KeyError, OSError):
            return None
        try:
            argv = strip_field_codes(shlex.split(section.get("Exec", "")))
        except ValueError:
            return None
        if not argv:
            return None
        return {"name": section.get("Name", desktop_id),
                "icon": section.get("Icon", ""),
                "argv": argv}
    return None


def chrome_profile_icon(config_subdir, profile_dir):
    path = os.path.expanduser(
        "~/.config/%s/%s/Google Profile Picture.png" % (config_subdir, profile_dir))
    return path if os.path.isfile(path) else ""


def build_entries(desktop_id, desktop, chrome_state, firefox_ini):
    """the entries one desktop id contributes.

    chrome_state is a parsed Local State (or {}), firefox_ini the text of a
    profiles.ini (or ""). both are passed in rather than read here so the whole
    assembly is checkable without a browser installed.
    """
    basename = os.path.basename(desktop["argv"][0]).lower() if desktop["argv"] else ""
    name, icon = desktop["name"], desktop["icon"]
    out = []

    if basename in CHROMIUM_FAMILIES:
        subdir, family = CHROMIUM_FAMILIES[basename]
        for directory, label, email in chrome_profiles(chrome_state):
            out.append({
                "id": "%s/%s/%s" % (family, subdir, directory),
                "name": name,
                "detail": ("%s · %s" % (label, email)) if email else label,
                "icon": chrome_profile_icon(subdir, directory) or icon,
                "argv": desktop["argv"] + ["--profile-directory=" + directory],
                "private": False,
            })
        out.append({
            "id": "%s/%s/#incognito" % (family, subdir),
            "name": name, "detail": "Incognito", "icon": icon,
            "argv": desktop["argv"] + ["--incognito"], "private": True,
        })
        return out

    if "firefox" in basename:
        profiles = firefox_profiles(firefox_ini)
        for path, label in profiles:
            out.append({
                "id": "firefox/%s/%s" % (basename, path),
                "name": name, "detail": label, "icon": icon,
                # -P takes the *name*, which is read fresh on every discovery.
                # renaming the profile therefore changes this argument and
                # leaves the id above untouched, which is the point of keying
                # the id on Path.
                "argv": desktop["argv"] + ["-P", label],
                "private": False,
            })
        if not profiles:
            out.append({
                "id": "firefox/%s" % basename,
                "name": name, "detail": "", "icon": icon,
                "argv": list(desktop["argv"]), "private": False,
            })
        out.append({
            "id": "firefox/%s/#private" % basename,
            "name": name, "detail": "Private window", "icon": icon,
            "argv": desktop["argv"] + ["--private-window"], "private": True,
        })
        return out

    # anything else registered for https: one entry, no profiles. keyed on the
    # executable so a browser reachable through two desktop ids still dedups.
    return [{
        "id": "other/%s" % (basename or desktop_id),
        "name": name, "detail": "", "icon": icon,
        "argv": list(desktop["argv"]), "private": False,
    }]


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def _read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, ValueError):
        # ValueError catches UnicodeDecodeError -- a profiles.ini written under
        # a different locale is unreadable, not fatal, same as _read_json above.
        return ""


def entries():
    """every browser-and-profile that can open a url, deduped, in gio's order."""
    out, seen = [], set()
    for desktop_id in registered_handlers():
        if desktop_id in SELF_IDS:
            continue
        desktop = read_desktop(desktop_id)
        if not desktop:
            continue

        basename = os.path.basename(desktop["argv"][0]).lower()
        state, ini = {}, ""
        if basename in CHROMIUM_FAMILIES:
            state = _read_json(os.path.expanduser(
                "~/.config/%s/Local State" % CHROMIUM_FAMILIES[basename][0]))
        elif "firefox" in basename:
            ini = _read_text(os.path.expanduser(
                "~/.mozilla/firefox/profiles.ini"))
            if not ini:
                # the flatpak keeps its profiles inside its own sandbox home.
                ini = _read_text(os.path.expanduser(
                    "~/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini"))

        for entry in build_entries(desktop_id, desktop, state, ini):
            if entry["id"] in seen:
                continue
            seen.add(entry["id"])
            out.append(entry)
    return out


def load_config():
    config = _read_json(CONFIG_PATH)
    return config if isinstance(config, dict) else {}


def fallback(url):
    """launch the fallback browser with url, replacing this process.

    reached only when the shell did not take the url. picks the configured
    fallback, or the first entry that is neither hidden nor private -- a fresh
    install has no config and still has to open links.
    """
    config = load_config()
    hidden = set(config.get("hidden") or [])
    available = [e for e in entries() if e["id"] not in hidden]

    chosen = next((e for e in available if e["id"] == config.get("fallback")), None)
    if chosen is None:
        chosen = next((e for e in available if not e["private"]), None)
    if chosen is None:
        sys.exit("no browser registered for x-scheme-handler/https")

    os.execvp(chosen["argv"][0], chosen["argv"] + [url])


# --------------------------------------------------------------------- check

CHROME_STATE_FIXTURE = {
    "profile": {
        "profiles_order": ["Default", "Profile 1"],
        "info_cache": {
            "Profile 1": {"name": "calangotech.eu", "user_name": "igor@calangotech.eu"},
            "Default": {"name": "dropsolid.com", "user_name": "igor@dropsolid.com"},
            # present in info_cache but absent from profiles_order: chrome does
            # this for a profile created since the last time it rewrote the
            # order, and dropping it would hide a real profile.
            "Profile 2": {"name": "Igor", "user_name": ""},
        },
    }
}

FIREFOX_INI_FIXTURE = """\
[Install4F96D1932A9F858E]
Default=xy3k9p.work
Locked=1

[Profile1]
Name=personal
IsRelative=1
Path=a1b2c3.personal

[Profile0]
Name=work
IsRelative=1
Path=xy3k9p.work
Default=1

[General]
StartWithLastProfile=1
Version=2
"""


def run_check():
    failures = []

    def ok(label, cond):
        if not cond:
            failures.append(label)
        print(("ok   " if cond else "FAIL ") + label)

    # chrome: profiles_order first, then anything only info_cache knows about.
    got = chrome_profiles(CHROME_STATE_FIXTURE)
    ok("chrome: ordered by profiles_order",
       [d for d, _, _ in got] == ["Default", "Profile 1", "Profile 2"])
    ok("chrome: display name from info_cache",
       [n for _, n, _ in got] == ["dropsolid.com", "calangotech.eu", "Igor"])
    ok("chrome: empty user_name stays empty",
       got[2][2] == "")

    # a profiles_order naming something info_cache has never heard of is stale,
    # not a profile. vala's version emits it anyway and gets an entry that
    # launches into a directory that does not exist.
    stale = {"profile": {"profiles_order": ["Default", "Ghost"],
                         "info_cache": {"Default": {"name": "d"}}}}
    ok("chrome: stale profiles_order entry dropped",
       [d for d, _, _ in chrome_profiles(stale)] == ["Default"])

    ok("chrome: no profile section is no profiles",
       chrome_profiles({}) == [])

    # firefox: sections are Profile0/Profile1, and Install*/General are not
    # profiles however much the prefix looks close.
    fx = firefox_profiles(FIREFOX_INI_FIXTURE)
    ok("firefox: only Profile* sections",
       sorted(p for p, _ in fx) == ["a1b2c3.personal", "xy3k9p.work"])
    ok("firefox: Path is the identity, Name is the label",
       dict(fx)["xy3k9p.work"] == "work")

    # the case that motivated keying on Path: renaming a profile inside firefox
    # rewrites Name and leaves Path alone, so the id survives and only the
    # launch argument moves.
    renamed = FIREFOX_INI_FIXTURE.replace("Name=work", "Name=$dayjob")
    ok("firefox: rename moves the label, not the id",
       [p for p, _ in firefox_profiles(renamed)] == [p for p, _ in fx]
       and dict(firefox_profiles(renamed))["xy3k9p.work"] == "$dayjob")

    ok("firefox: no profiles.ini is no profiles",
       firefox_profiles("") == [])

    # exec field codes. quickshell strips most of these itself, unreliably; here
    # there is no quickshell, so it is all ours.
    ok("exec: %U and friends dropped",
       strip_field_codes(["/usr/bin/google-chrome-stable", "%U"])
       == ["/usr/bin/google-chrome-stable"])
    ok("exec: a bare percent argument survives",
       strip_field_codes(["firefox", "%", "%u"]) == ["firefox", "%"])
    ok("exec: a real argument that starts with % survives",
       strip_field_codes(["app", "%value"]) == ["app", "%value"])

    # the executable-basename table, which is what makes two desktop ids for one
    # browser collapse to one set of entries.
    ok("families: chrome aliases share a config dir",
       CHROMIUM_FAMILIES["google-chrome"][0]
       == CHROMIUM_FAMILIES["google-chrome-stable"][0] == "google-chrome")
    ok("families: brave nests under BraveSoftware",
       CHROMIUM_FAMILIES["brave-browser"][0] == "BraveSoftware/Brave-Browser")
    ok("families: firefox is not in the chromium table",
       "firefox" not in CHROMIUM_FAMILIES)

    # entry assembly. build_entries takes what the filesystem would have given
    # us, so the shape can be checked without a browser installed.
    chrome_desktop = {"name": "Google Chrome", "icon": "google-chrome",
                      "argv": ["/usr/bin/google-chrome-stable"]}
    built = build_entries("com.google.Chrome.desktop", chrome_desktop,
                          CHROME_STATE_FIXTURE, "")
    ok("entries: one per chrome profile, plus incognito",
       [e["id"] for e in built] == [
           "chrome/google-chrome/Default",
           "chrome/google-chrome/Profile 1",
           "chrome/google-chrome/Profile 2",
           "chrome/google-chrome/#incognito",
       ])
    ok("entries: profile argument carries the directory",
       built[1]["argv"] == ["/usr/bin/google-chrome-stable",
                            "--profile-directory=Profile 1"])
    ok("entries: incognito is marked private",
       built[-1]["private"] is True and built[0]["private"] is False)
    ok("entries: detail pairs the profile name with its email",
       built[0]["detail"] == "dropsolid.com · igor@dropsolid.com")

    # the dedup that the whole id scheme exists for: the same browser reached
    # through its other desktop id must add nothing.
    other = build_entries("google-chrome.desktop", chrome_desktop,
                          CHROME_STATE_FIXTURE, "")
    ok("entries: a second desktop id for one browser collides away",
       [e["id"] for e in other] == [e["id"] for e in built])

    # a non-utf8 profiles.ini (locale mismatch, partial write) must degrade to
    # "no firefox profiles" rather than crash discovery, same as _read_json
    # already does for unparseable json.
    with tempfile.NamedTemporaryFile(delete=False) as handle:
        handle.write(b"\xff\xfe not utf-8")
        bad_path = handle.name
    try:
        ok("_read_text: invalid utf-8 returns empty string, not a crash",
           _read_text(bad_path) == "")
    finally:
        os.unlink(bad_path)

    # a Local State that parsed but is not the dict we expect (list, string,
    # None) is "no chrome profiles", not a crash.
    ok("chrome_profiles: non-dict Local State returns no profiles, not a crash",
       chrome_profiles([]) == [] and chrome_profiles("x") == []
       and chrome_profiles(None) == [])

    print()
    print("%d checks, %d failed" % (22, len(failures)))
    return 1 if failures else 0


def main(argv):
    if "--check" in argv:
        return run_check()
    if "--fallback" in argv:
        rest = argv[argv.index("--fallback") + 1:]
        # calango-open passes "--" ahead of the url as defense-in-depth against
        # a url that happens to look like a flag; skip it if it is there so
        # `--fallback URL` and `--fallback -- URL` both work.
        if rest[:1] == ["--"]:
            rest = rest[1:]
        if not rest:
            sys.exit("--fallback needs a url")
        fallback(rest[0])  # never returns
    json.dump(entries(), sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

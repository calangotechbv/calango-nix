pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Singleton {
    id: root

    property list<var> notifications: []
    property bool doNotDisturb: false
    readonly property int count: notifications.length
    property int _seqCounter: 0

    // ---------------------------------------------------------------- history

    // Plain JS records rather than NotificationData objects. A NotificationData
    // wraps a Notification that quickshell destroys once the popup closes, so
    // anything meant to outlive the popup has to be a snapshot taken while the
    // fields are still readable.
    property var history: []
    readonly property int historyLimit: 100

    // Arrivals since the centre was last opened. This is the number that belongs
    // on the bar badge -- history.length only ever grows, whether or not any of
    // it has been read.
    property int unreadCount: 0

    // Flips once the on-disk history has been read back. Until then saving is
    // suppressed: a notification arriving in the first few hundred milliseconds
    // would otherwise write a one-entry file over the real one.
    property bool _loaded: false

    function _snapshot(n) {
        return {
            key:     String(root._seqCounter++),
            appName: n.appName || "",
            appIcon: n.appIcon || "",
            summary: n.summary || "",
            body:    n.body    || "",
            image:   n.image   || "",
            urgency: n.urgency,
            time:    Date.now()
        };
    }

    function _pushHistory(rec) {
        const next = [rec, ...root.history];
        root.history = next.length > root.historyLimit
                     ? next.slice(0, root.historyLimit)
                     : next;
    }

    function clearHistory(): void {
        root.history = [];
        root.unreadCount = 0;
    }

    function removeFromHistory(key): void {
        root.history = root.history.filter(function(r) { return r.key !== key; });
    }

    function markAllRead(): void {
        root.unreadCount = 0;
    }

    Component {
        id: notifDataComp
        NotificationData {}
    }

    NotificationServer {
        id: server
        actionsSupported:    true
        bodySupported:       true
        bodyMarkupSupported: true
        imageSupported:      true
        keepOnReload:        false

        onNotification: function(notification) {
            if (!notification.appName && !notification.summary
                && !notification.body && !notification.image) return;

            // Do not disturb suppresses the popup, not the notification. The
            // snapshot is taken synchronously here, while the Notification is
            // still alive, so leaving it untracked is safe -- and untracked is
            // exactly what keeps it off the screen.
            if (root.doNotDisturb) {
                root._pushHistory(root._snapshot(notification));
                root.unreadCount++;
                return;
            }

            notification.tracked = true;

            const idStr = String(notification.id || "");
            if (idStr !== "") {
                const existing = root.notifications.find(function(n) {
                    return n.notifId === idStr;
                });
                // A replacement, not a new event -- apps reuse an id to update in
                // place (download progress, track changes). Dropping it without
                // archiving is deliberate: recording every tick would bury the
                // history under one noisy sender.
                if (existing && !existing.closed) {
                    existing.closed = true;
                    root.notifications = root.notifications.filter(function(n) {
                        return n !== existing;
                    });
                    existing.destroy();
                }
            }

            const data = notifDataComp.createObject(root, {
                notification: notification,
                seqId: String(root._seqCounter++)
            });

            root.notifications = [data, ...root.notifications];
            root.unreadCount++;

            if (root.notifications.length > 5) {
                root.notifications[root.notifications.length - 1].dismiss();
            }
        }
    }

    // Every route out of the popup list funnels through here -- expiry, click,
    // action, overflow, and the app closing it remotely -- which makes it the
    // one place archiving has to happen. Guarded on membership so the second
    // call for an already-removed notification cannot duplicate the record.
    function _remove(notifData): void {
        if (notifData && root.notifications.indexOf(notifData) !== -1)
            root._pushHistory(root._snapshot(notifData));

        root.notifications = root.notifications.filter(function(n) {
            return n !== notifData;
        });
    }

    function dismiss(notifData): void {
        if (notifData) notifData.dismiss();
    }

    function dismissAll(): void {
        const toRemove = [...root.notifications];
        root.notifications = [];
        for (const n of toRemove) {
            if (!n.closed) {
                n.closed = true;
                root._pushHistory(root._snapshot(n));
                if (n.notification) try { n.notification.dismiss(); } catch(e) {}
                n.destroy();
            }
        }
    }

    // ------------------------------------------------------------ persistence

    // Read with a Process rather than a FileView so the "file does not exist
    // yet" case still produces a completion signal -- _loaded has to flip either
    // way, or saving stays disabled forever on a fresh install.
    Process {
        id: historyLoadProc
        command: ["sh", "-c", "cat ${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/notification-history.json 2>/dev/null"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = text.trim();
                if (raw !== "") {
                    try {
                        const loaded = JSON.parse(raw);
                        if (Array.isArray(loaded)) {
                            // Merge rather than assign: notifications can arrive
                            // before the read completes, and those are the ones
                            // the user is most likely to be looking for.
                            const merged = [...root.history, ...loaded]
                                .sort(function(a, b) { return b.time - a.time; });
                            root.history = merged.slice(0, root.historyLimit);
                        }
                    } catch (e) {
                        console.error("NotificationService: bad notification-history.json:", e);
                    }
                }
                root._loaded = true;
            }
        }
    }

    Process { id: historySaveProc; running: false }

    // Debounced: a burst of notifications should cost one write, not one each.
    Timer {
        id: saveTimer
        interval: 1000
        onTriggered: {
            // Images are dropped on the way to disk. notification.image is a
            // pixmap handed over the bus or a path into the sender's temp dir;
            // either way the reference is dead by the next session, so persisting
            // it only buys broken thumbnails. appIcon survives because it is an
            // icon *name*, resolved fresh at paint time.
            const payload = JSON.stringify(root.history.map(function(r) {
                return {
                    key: r.key, appName: r.appName, appIcon: r.appIcon,
                    summary: r.summary, body: r.body,
                    urgency: r.urgency, time: r.time
                };
            }));
            historySaveProc.command = ["sh", "-c",
                'printf "%s" "$1" > "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/notification-history.json"',
                "sh", payload];
            historySaveProc.running = true;
        }
    }

    onHistoryChanged: if (root._loaded) saveTimer.restart()
}

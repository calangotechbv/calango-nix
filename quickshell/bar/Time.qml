pragma Singleton

import Quickshell
import QtQuick

Singleton {
  id: root

  readonly property string timeString: {
    Qt.formatDateTime(clock.date, "hh:mm")
  }

  readonly property string dateString: {
    Qt.formatDateTime(clock.date, "ddd MMM d")
  }

  // The current day as yyyy-MM-dd, for anything that has to notice midnight.
  //
  // Derived from a Seconds-precision clock but only *changes* once a day, so a
  // binding on it re-evaluates once at midnight rather than 86,400 times
  // getting there -- QML propagates on change, not on re-evaluation of the
  // source.
  readonly property string dayStamp: {
    Qt.formatDateTime(clock.date, "yyyy-MM-dd")
  }

  SystemClock {
    id: clock
    precision: SystemClock.Seconds
  }
}

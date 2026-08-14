// A 1px horizontal rule, for use inside a ColumnLayout.
//
// Layout.preferredHeight rather than height, for the same reason every other
// layout child in this tree stopped setting height in f34780d: `height` on an
// item a layout manages is undefined behaviour -- it holds until the layout
// next recomputes, and what happens then is not specified. preferredHeight is
// the defined way to ask for the same 1px.
//
// This file is why the fix needed a human. The linter checks one file at a
// time, so here it sees a Rectangle whose parent it cannot know, and at the
// five call sites it sees `Divider {}` with no height in view -- the fault is
// split across two files and visible in neither. It was absent from the 46
// warnings reported by 6.11, and was the same defect all along.
//
// Note the wording above avoids starting a comment line with the linter's own
// name: a `//` comment beginning with it is parsed as a lint directive, and
// every following word is read as a category. Saying so cost ten
// invalid-lint-directive warnings the first time this comment was written.
//
// Every use is a ColumnLayout child (MonitorPanel ×4, SettingsPanel ×1), so
// there is no non-layout caller for whom the old `height` was the right key.
import QtQuick
import QtQuick.Layouts

Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: 1
}

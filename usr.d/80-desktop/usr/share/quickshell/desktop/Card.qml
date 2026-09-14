import QtQuick
import "theme"

Rectangle {
    default property alias content: inner.data

    property alias spacing: inner.spacing

    implicitWidth: 340
    implicitHeight: inner.implicitHeight + Theme.pad * 2

    radius: Theme.radius
    color: Theme.elevated
    border.width: 1
    border.color: Theme.border

    Column {
        id: inner

        anchors.centerIn: parent
        width: parent.width - Theme.pad * 2
        spacing: Theme.pad
    }
}

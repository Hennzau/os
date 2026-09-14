import QtQuick
import "theme"

Item {
    id: root

    property real value: 0
    property color fill: Theme.accent

    signal moved(real value)

    implicitHeight: 16
    implicitWidth: 130

    Rectangle {
        id: track

        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 5
        radius: height / 2
        color: Theme.border

        Rectangle {
            width: track.width * Math.max(0, Math.min(1, root.value))
            height: parent.height
            radius: parent.radius
            color: root.fill
        }
    }

    Rectangle {
        x: (root.width - width) * Math.max(0, Math.min(1, root.value))
        anchors.verticalCenter: parent.verticalCenter
        width: 12
        height: 12
        radius: width / 2
        color: Theme.elevated
        border.width: 1
        border.color: drag.pressed ? Theme.focused : Theme.border
    }

    MouseArea {
        id: drag

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor

        function apply(x) {
            root.moved(Math.max(0, Math.min(1, x / root.width)));
        }

        onPressed: mouse => apply(mouse.x)
        onPositionChanged: mouse => {
            if (pressed)
                apply(mouse.x);
        }
    }
}

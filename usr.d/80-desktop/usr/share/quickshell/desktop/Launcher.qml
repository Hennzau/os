import QtQuick
import Quickshell
import Quickshell.Io
import "theme"

Rectangle {
    id: root

    implicitWidth: 22
    implicitHeight: Theme.barHeight - 4
    radius: Theme.radiusSmall
    color: mouse.containsMouse ? Theme.hover : "transparent"

    Process {
        id: launch
    }

    Grid {
        anchors.centerIn: parent

        rows: 3
        columns: 3
        spacing: 2

        Repeater {
            model: 9

            Rectangle {
                width: 2
                height: 2
                radius: 1
                color: mouse.containsMouse ? Theme.accent : Theme.muted

                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }
            }
        }
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor

        onClicked: {
            launch.command = ["fuzzel"];
            launch.startDetached();
        }
    }
}

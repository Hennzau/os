import QtQuick
import Quickshell
import Quickshell.Io
import "theme"

Rectangle {
    id: root

    property bool sessionActions: true

    property bool open: false

    readonly property var entries: {
        const session = [
            {
                label: "Lock",
                cmd: ["elvos-lock"]
            },
            {
                label: "Log out",
                cmd: ["niri", "msg", "action", "quit", "--skip-confirmation"]
            }
        ];
        const suspend = root.sessionActions ? {
            label: "Suspend",
            cmd: ["sh", "-c", "elvos-lock & sleep 0.3; systemctl suspend"]
        } : {
            label: "Suspend",
            cmd: ["systemctl", "suspend"]
        };

        const machine = [suspend,
            {
                label: "Restart",
                cmd: ["systemctl", "reboot"]
            },
            {
                label: "Power off",
                cmd: ["systemctl", "poweroff"]
            }
        ];
        return root.sessionActions ? session.concat(machine) : machine;
    }

    implicitWidth: 150
    implicitHeight: column.implicitHeight + Theme.padSmall * 2

    radius: Theme.radius
    color: Theme.elevated
    border.width: 1
    border.color: Theme.border

    visible: opacity > 0
    opacity: root.open ? 1 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    Process {
        id: runner
    }

    Column {
        id: column

        anchors.centerIn: parent
        width: parent.width - Theme.padSmall * 2

        Repeater {
            model: root.entries

            Rectangle {
                required property var modelData

                width: parent.width
                height: 26
                radius: Theme.radiusSmall
                color: hover.containsMouse ? Theme.hover : "transparent"

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.padSmall
                    text: modelData.label
                    color: modelData.label === "Power off" ? Theme.error : Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }

                MouseArea {
                    id: hover

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        root.open = false;
                        runner.command = modelData.cmd;
                        runner.startDetached();
                    }
                }
            }
        }
    }
}

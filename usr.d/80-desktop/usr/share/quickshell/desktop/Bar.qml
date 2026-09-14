import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "theme"

Item {
    id: root

    property bool showWorkspaces: true
    property bool showLauncher: true
    property string screenName: ""

    property bool sessionActions: true

    readonly property bool panelOpen: menu.open || control.open

    function closePanels() {
        menu.open = false;
        control.open = false;
    }
    property alias stripItem: strip
    property string network: ""
    property bool idleInhibited: false

    implicitHeight: Theme.barHeight

    Process {
        id: netProbe

        command: ["/usr/bin/elvos-net-status"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root.network = text.trim()
        }
    }

    Timer {
        interval: 10000
        running: true
        repeat: true
        onTriggered: netProbe.running = true
    }

    SystemClock {
        id: clock

        precision: SystemClock.Minutes
    }

    Rectangle {
        id: strip

        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }

        height: Theme.barHeight
        color: Theme.panel

        bottomLeftRadius: Theme.radius - 5
        bottomRightRadius: Theme.radius - 5

        Launcher {
            id: launcher

            visible: root.showLauncher

            anchors {
                left: parent.left
                leftMargin: Theme.padSmall
                verticalCenter: parent.verticalCenter
            }
        }

        Workspaces {
            visible: root.showWorkspaces
            output: root.screenName

            anchors {
                left: launcher.visible ? launcher.right : parent.left
                leftMargin: Theme.padSmall
                verticalCenter: parent.verticalCenter
            }
        }

        Rectangle {
            id: clockButton

            anchors.centerIn: parent
            width: clockText.implicitWidth + Theme.pad
            height: Theme.barHeight - 4
            radius: Theme.radiusSmall
            color: control.open ? Theme.active : clockMouse.containsMouse ? Theme.hover : "transparent"

            Text {
                id: clockText

                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter

                text: Qt.formatDateTime(clock.date, "ddd d MMM  HH:mm")
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
            }

            MouseArea {
                id: clockMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                onClicked: {
                    menu.open = false;
                    control.open = !control.open;
                }
            }
        }

        Row {
            id: status

            anchors {
                right: parent.right
                rightMargin: Theme.padSmall
                top: parent.top
                bottom: parent.bottom
            }

            spacing: Theme.padSmall

            Text {
                height: status.height
                verticalAlignment: Text.AlignVCenter
                visible: root.idleInhibited
                text: "awake"
                color: Theme.warning
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
            }

            Text {
                height: status.height
                verticalAlignment: Text.AlignVCenter
                text: root.network === "" ? "offline" : root.network
                color: root.network === "" ? Theme.placeholder : Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
            }

            Text {
                readonly property var battery: UPower.displayDevice

                height: status.height
                verticalAlignment: Text.AlignVCenter
                visible: battery.ready && battery.isLaptopBattery
                text: Math.round(battery.percentage * 100) + "%" + (battery.state === UPowerDeviceState.Charging ? " +" : "")
                color: battery.state === UPowerDeviceState.Charging ? Theme.success : battery.percentage < 0.15 ? Theme.error : Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
            }

            Rectangle {
                y: (status.height - height) / 2
                width: 22
                height: Theme.barHeight - 4
                radius: Theme.radiusSmall
                color: menu.open ? Theme.active : power.containsMouse ? Theme.hover : "transparent"

                Text {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: "⏻"
                    color: Theme.fg
                    font.family: Theme.monoFamily
                    font.pixelSize: 15
                }

                MouseArea {
                    id: power

                    anchors.fill: parent
                    anchors.topMargin: -parent.y
                    anchors.bottomMargin: -parent.y
                    anchors.rightMargin: -Theme.padSmall
                    anchors.leftMargin: -Theme.padSmall

                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        control.open = false;
                        menu.open = !menu.open;
                    }
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        focus: root.panelOpen

        Keys.onEscapePressed: {
            menu.open = false;
            control.open = false;
        }
    }

    PowerMenu {
        id: menu

        sessionActions: root.sessionActions

        anchors {
            top: strip.bottom
            topMargin: 4
            right: strip.right
            rightMargin: Theme.padSmall
        }
    }

    ControlPanel {
        id: control

        anchors {
            top: strip.bottom
            topMargin: 4
            horizontalCenter: strip.horizontalCenter
        }
    }
}

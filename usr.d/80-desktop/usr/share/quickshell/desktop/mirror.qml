import QtQuick
import Quickshell
import Quickshell.Io
import "theme"

ShellRoot {
    id: root

    property string source: ""
    property string target: ""

    readonly property bool valid: root.source !== "" && root.target !== "" && root.source !== root.target

    Process {
        id: mirror
    }

    function start() {
        if (!root.valid)
            return;

        mirror.command = ["wl-mirror", "--fullscreen-output", root.target, root.source];
        mirror.startDetached();
        Qt.quit();
    }

    component OutputList: Column {
        property string heading: ""
        property string selected: ""

        signal picked(string name)

        spacing: 4

        Text {
            text: parent.heading
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSmall
        }

        Repeater {
            model: Quickshell.screens

            Rectangle {
                required property var modelData

                width: 150
                height: 40
                radius: Theme.radiusSmall
                color: modelData.name === selected ? Theme.accent : hover.containsMouse ? Theme.hover : Theme.canvas
                border.width: 1
                border.color: modelData.name === selected ? Theme.accent : Theme.border

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.padSmall
                    width: parent.width - Theme.padSmall * 2

                    Text {
                        text: modelData.name
                        color: modelData.name === selected ? Theme.elevated : Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Text {
                        text: modelData.model
                        color: modelData.name === selected ? Theme.elevated : Theme.placeholder
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall - 1
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                MouseArea {
                    id: hover

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picked(modelData.name)
                }
            }
        }
    }

    FloatingWindow {
        title: "elvOS Mirror"

        color: "transparent"
        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight

        Card {
            id: card

            implicitWidth: 340

            focus: true
            Keys.onEscapePressed: Qt.quit()
            Keys.onReturnPressed: root.start()

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Mirror an output"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: 16
            }

            Row {
                width: parent.width
                spacing: Theme.pad

                OutputList {
                    heading: "Mirror"
                    selected: root.source
                    onPicked: name => root.source = name
                }

                OutputList {
                    heading: "Onto"
                    selected: root.target
                    onPicked: name => root.target = name
                }
            }

            Rectangle {
                width: parent.width
                height: 32
                radius: Theme.radiusSmall
                color: root.valid ? (go.containsMouse ? Theme.focused : Theme.accent) : Theme.active
                opacity: root.valid ? 1 : 0.5

                Text {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.source === root.target && root.source !== "" ? "Pick two different outputs" : "Start mirroring"
                    color: root.valid ? Theme.elevated : Theme.placeholder
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }

                MouseArea {
                    id: go

                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.valid
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.start()
                }
            }
        }
    }
}

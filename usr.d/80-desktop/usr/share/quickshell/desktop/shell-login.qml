import QtQuick
import Quickshell
import Quickshell.Wayland
import "theme"

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property var modelData
            screen: modelData

            anchors {
                top: true
                left: true
                right: true
            }

            implicitHeight: modelData.height

            exclusionMode: ExclusionMode.Normal
            exclusiveZone: Theme.barHeight

            color: "transparent"

            WlrLayershell.keyboardFocus: bar.panelOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            mask: bar.panelOpen ? null : stripOnly

            Region {
                id: stripOnly

                item: bar.stripItem
            }

            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: bar.panelOpen
                onClicked: bar.closePanels()
            }

            Bar {
                id: bar

                screenName: win.screen ? win.screen.name : ""

                showWorkspaces: false
                showLauncher: false
                sessionActions: false

                anchors.fill: parent
            }
        }
    }
}

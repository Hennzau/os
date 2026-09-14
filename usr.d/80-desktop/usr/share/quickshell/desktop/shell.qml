import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "theme"

ShellRoot {
    Idle {
        id: idle
    }

    // qs ipc call idle toggle|on|off|status
    IpcHandler {
        target: "idle"

        function toggle(): string {
            idle.inhibited = !idle.inhibited;
            return status();
        }

        function on(): string {
            idle.inhibited = true;
            return status();
        }

        function off(): string {
            idle.inhibited = false;
            return status();
        }

        function status(): string {
            return idle.inhibited ? "awake" : "idle";
        }
    }

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
                idleInhibited: idle.inhibited

                anchors.fill: parent
            }
        }
    }
}

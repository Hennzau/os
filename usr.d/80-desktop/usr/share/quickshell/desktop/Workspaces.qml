import QtQuick
import Quickshell
import Quickshell.Io
import "theme"

Row {
    id: root

    property var workspaces: []

    property string output: ""

    readonly property var shown: root.output === "" ? root.workspaces : root.workspaces.filter(w => w.output === root.output)

    readonly property string focusedOutput: {
        const focused = root.workspaces.find(w => w.is_focused);
        return focused ? focused.output : "";
    }

    property bool overview: false

    spacing: root.overview ? Theme.padSmall : Theme.padSmall / 2

    Behavior on spacing {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
        }
    }

    Process {
        running: true
        command: ["niri", "msg", "--json", "event-stream"]

        stdout: SplitParser {
            onRead: line => {
                if (line.startsWith('{"OverviewOpenedOrClosed')) {
                    try {
                        root.overview = JSON.parse(line).OverviewOpenedOrClosed.is_open;
                    } catch (e) {}
                    return;
                }

                if (!line.startsWith('{"Workspace'))
                    return;

                let ev;
                try {
                    ev = JSON.parse(line);
                } catch (e) {
                    return;
                }

                if (ev.WorkspacesChanged) {
                    root.workspaces = ev.WorkspacesChanged.workspaces.slice().sort((a, b) => a.idx - b.idx);
                } else if (ev.WorkspaceActivated) {
                    const id = ev.WorkspaceActivated.id;
                    root.workspaces = root.workspaces.map(w => {
                        const c = Object.assign({}, w);
                        c.is_focused = c.id === id;
                        c.is_active = c.id === id;
                        return c;
                    });
                }
            }
        }
    }

    Process {
        id: focusWorkspace
    }

    Repeater {
        model: root.shown

        Rectangle {
            required property var modelData

            width: Math.max(root.overview ? 30 : 18, label.implicitWidth + Theme.padSmall)
            height: root.overview ? Theme.barHeight - 4 : Theme.barHeight - 8
            radius: Theme.radiusSmall

            Behavior on width {
                NumberAnimation {
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on height {
                NumberAnimation {
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }

            color: modelData.is_focused ? Theme.accent : mouse.containsMouse ? Theme.hover : "transparent"

            border.width: 1
            border.color: modelData.is_urgent ? Theme.error : modelData.is_focused ? Theme.accent : Theme.border

            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }

            Text {
                id: label

                anchors.centerIn: parent
                text: modelData.name ? modelData.name : modelData.idx
                color: modelData.is_focused ? Theme.elevated : Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
            }

            MouseArea {
                id: mouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                onClicked: {
                    if (modelData.output === root.focusedOutput) {
                        focusWorkspace.command = ["niri", "msg", "action", "focus-workspace", String(modelData.idx)];
                    } else {
                        focusWorkspace.command = ["sh", "-c", "niri msg action focus-monitor '" + modelData.output + "' && niri msg action focus-workspace " + modelData.idx];
                    }

                    focusWorkspace.startDetached();
                }
            }
        }
    }
}

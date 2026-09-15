pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import "theme"

Rectangle {
    id: root

    property bool open: false
    property real brightness: 0

    PwObjectTracker {
        objects: Pipewire.nodes.values
    }

    property var available: []

    Process {
        id: nodeProbe

        command: ["/usr/bin/elvos-audio-nodes"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root.available = text.trim().split("\n").filter(line => line !== "")
        }
    }

    // A device that comes or goes while the panel is open (Bluetooth
    // headphones) changes the node list: probe again. Opening the panel
    // probes too, for ports plugged in or out since.
    Connections {
        target: Pipewire.nodes

        function onValuesChanged() {
            nodeProbe.running = true;
        }
    }

    function usable(node) {
        return node.audio && !node.isStream && root.available.includes(node.properties["node.name"]);
    }

    readonly property var sinks: Pipewire.nodes.values.filter(n => n.isSink && root.usable(n))
    readonly property var sources: Pipewire.nodes.values.filter(n => !n.isSink && root.usable(n))

    function label(node) {
        if (!node)
            return "none";
        return node.nickname || node.description || node.name;
    }

    Process {
        id: brightnessRead

        command: ["brightnessctl", "-m"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(",");
                if (parts.length >= 4)
                    root.brightness = parseInt(parts[3]) / 100;
            }
        }
    }

    Process {
        id: brightnessWrite
    }

    function setBrightness(v) {
        const pct = Math.max(1, Math.round(v * 100));
        root.brightness = pct / 100;
        brightnessWrite.command = ["brightnessctl", "set", pct + "%"];
        brightnessWrite.startDetached();
    }

    onOpenChanged: if (open) {
        brightnessRead.running = true;
        nodeProbe.running = true;
    }

    implicitWidth: 268
    implicitHeight: column.implicitHeight + Theme.pad * 2

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

    component Heading: Text {
        color: Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSmall
    }

    component DeviceList: Column {
        id: list

        property var nodes: []
        property var current: null

        signal picked(var node)

        width: parent.width
        spacing: 2

        Repeater {
            model: parent.nodes

            Rectangle {
                id: item

                required property var modelData

                width: parent.width
                height: 22
                radius: Theme.radiusSmall
                color: item.modelData === list.current ? Theme.active : pick.containsMouse ? Theme.hover : "transparent"

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.padSmall
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: root.label(item.modelData)
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }

                MouseArea {
                    id: pick

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: list.picked(item.modelData)
                }
            }
        }
    }

    Column {
        id: column

        anchors.centerIn: parent
        width: parent.width - Theme.pad * 2
        spacing: Theme.padSmall

        Heading {
            text: "Brightness  " + Math.round(root.brightness * 100) + "%"
        }

        Slider {
            width: parent.width
            value: root.brightness
            fill: Theme.warning
            onMoved: v => root.setBrightness(v)
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.border
        }

        Heading {
            readonly property var sink: Pipewire.defaultAudioSink

            text: "Output  " + (sink && sink.audio ? Math.round(sink.audio.volume * 100) + "%" : "-") + (sink && sink.audio && sink.audio.muted ? "  muted" : "")
        }

        Slider {
            readonly property var sink: Pipewire.defaultAudioSink

            width: parent.width
            value: sink && sink.audio ? sink.audio.volume : 0
            fill: sink && sink.audio && sink.audio.muted ? Theme.placeholder : Theme.accent

            onMoved: v => {
                if (sink && sink.audio)
                    sink.audio.volume = v;
            }
        }

        DeviceList {
            nodes: root.sinks
            current: Pipewire.defaultAudioSink
            onPicked: node => Pipewire.preferredDefaultAudioSink = node
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.border
        }

        Heading {
            readonly property var source: Pipewire.defaultAudioSource

            text: "Input  " + (source && source.audio ? Math.round(source.audio.volume * 100) + "%" : "-") + (source && source.audio && source.audio.muted ? "  muted" : "")
        }

        Slider {
            readonly property var source: Pipewire.defaultAudioSource

            width: parent.width
            value: source && source.audio ? source.audio.volume : 0
            fill: source && source.audio && source.audio.muted ? Theme.placeholder : Theme.success

            onMoved: v => {
                if (source && source.audio)
                    source.audio.volume = v;
            }
        }

        DeviceList {
            nodes: root.sources
            current: Pipewire.defaultAudioSource
            onPicked: node => Pipewire.preferredDefaultAudioSource = node
        }
    }
}
